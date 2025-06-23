library(httr)
library(jsonlite)


#########################
# Configuración inicial #
#########################

# Configuración Prometheus
prom_url <- "http://prometheus.monitoring.svc.cluster.local:9090"
query_prometheus <- function(q) {
  res <- GET(paste0(prom_url, "/api/v1/query"), query = list(query = q))
  stop_for_status(res)
  dat <- content(res, as = "parsed")
  if (dat$status != "success" || length(dat$data$result) == 0) return(NA_real_)
  as.numeric(dat$data$result[[1]]$value[2])
}

# Configuración Kubernetes
token <- suppressWarnings(paste(readLines("/var/run/secrets/kubernetes.io/serviceaccount/token"), collapse = ""))
ca_cert <- "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
k8s_host <- Sys.getenv("KUBERNETES_SERVICE_HOST")
k8s_port <- Sys.getenv("KUBERNETES_SERVICE_PORT")
base_url <- paste0("https://", k8s_host, ":", k8s_port)
deployment_url <- paste0(base_url,
                         "/apis/apps/v1/namespaces/web-namespace/deployments/web-deployment")

# Parámetros de la prueba
duration_secs <- 340  # Duración total en segundos
interval <- 15         # Intervalo entre iteraciones
start_time <- Sys.time()
events <- 0
warmup_period_secs <- 60  # Período de calentamiento de 60 segundos

# Parámetros de escalado
min_replicas <- 2
target_util  <- 0.8
alpha        <- 0.8   # Peso EMA para λ suavizada
delta_up     <- 0.1   # Umbral +10% para escalar hacia arriba
delta_down   <- 0.1   # Umbral -10% para escalar hacia abajo
max_step     <- 10    # Máx. cambio de réplicas por iteración
mu           <- 170   # Mu máximo del sistema, calculado en ..._mu_checker.R: μ estimado por réplica ≈ 178.85 rps (con 2 réplicas)
# Con el sistema saturado el máximo throughput es de 113

# Métricas iniciales
deploy <- GET(deployment_url, add_headers(Authorization = paste("Bearer", token)), config(cainfo = ca_cert))
stop_for_status(deploy)
replicas_prev <- content(deploy, as="parsed")$spec$replicas
initial_replicas <- replicas_prev
last_replicas <- replicas_prev

lambda_init <- query_prometheus('sum(rate(nginx_http_requests_total[1m]))')
l_prev      <- ifelse(is.na(lambda_init), 0, lambda_init)

total_req_i <- query_prometheus('sum(nginx_http_requests_total)')

# Vectores para almacenar métricas
data <- list(
  timestamp        = numeric(),
  lambda           = numeric(),
  throughput       = numeric(),
  utilization      = numeric(),
  response_avg_rate= numeric(),
  queue_avg        = numeric(),
  queue_max        = numeric(),
  active_conn      = numeric(),
  gc_dur_p75       = numeric(),
  heap_ratio       = numeric(),
  replicas_history = numeric()
)


#################################################################################################################
# Bucle de monitoreo # lectura → métricas → conteo eventos → guardado → escalado → actualización estado → sleep #
#################################################################################################################

while (as.numeric(difftime(Sys.time(), start_time, units = "secs")) < duration_secs) {
  current_time <- Sys.time()
  elapsed_time <- as.numeric(difftime(current_time, start_time, units = "secs"))
  is_warmup <- elapsed_time < warmup_period_secs
  
  cat("\n########## Iteración ##########\n")
  if (is_warmup) {
    cat("PERÍODO DE CALENTAMIENTO - Las métricas no se utilizarán para análisis final\n")
  }
  
  #################################
  # Lectura actual del deployment #
  #################################
  
  deploy <- GET(deployment_url, add_headers(Authorization = paste("Bearer", token)), config(cainfo = ca_cert))
  stop_for_status(deploy)
  replicas_deploy <- content(deploy, as = "parsed")$spec$replicas
  
  
  #################################
  # Métricas λ, μ, ρ | Prometheus #
  #################################
  
  lambda <- query_prometheus('sum(rate(nginx_http_requests_total[1m]))')
  # Por la Ley de Little: λ = L/W
  throughput_global <- query_prometheus('sum(rate(nginx_http_response_count_total[1m]))')
  throughput <- ifelse(is.na(throughput_global) || throughput_global <= 0, NA_real_, throughput_global/replicas_deploy)
  utilization <- lambda / (replicas_deploy * mu)
  
  cat("λ: ", lambda, "	|	μ: ", mu, "	|	throughput: ", throughput, "	|	ρ: ", utilization, "\n")
  
  
  ##################
  # Otras métricas #
  ##################
  
  response_avg_rate <- query_prometheus('sum(rate(nginx_http_response_time_seconds_sum[1m])) / sum(rate(nginx_http_response_time_seconds_count[1m]))')
  queue_avg         <- query_prometheus('avg(nginx_connections_waiting)')
  queue_max         <- query_prometheus('max(nginx_connections_waiting)')
  active_conn       <- query_prometheus('sum(nginx_connections_active)')
  gc_dur_p75        <- query_prometheus('go_gc_duration_seconds{quantile="0.75"}')
  heap_ratio        <- query_prometheus('sum(go_memstats_heap_alloc_bytes) / sum(go_gc_gomemlimit_bytes)')
  
  # Contar eventos de cambio de replicas
  if (replicas_deploy != last_replicas) {
    events <- events + 1
  }
  last_replicas <- replicas_deploy
  
  
  #####################
  # Guardar historial #
  #####################
  
  data$timestamp        <- c(data$timestamp, elapsed_time)
  data$lambda           <- c(data$lambda, lambda)
  data$throughput       <- c(data$throughput, throughput)
  data$utilization      <- c(data$utilization, utilization)
  data$response_avg_rate<- c(data$response_avg_rate, response_avg_rate)
  data$queue_avg        <- c(data$queue_avg, queue_avg)
  data$queue_max        <- c(data$queue_max, queue_max)
  data$active_conn      <- c(data$active_conn, active_conn)
  data$gc_dur_p75       <- c(data$gc_dur_p75, gc_dur_p75)
  data$heap_ratio       <- c(data$heap_ratio, heap_ratio)
  data$replicas_history <- c(data$replicas_history, replicas_deploy)
  
  
  ########################
  # Cálculo del escalado #
  ########################
  
  # EMA de λ
  l_t <- alpha * l_prev + (1 - alpha) * lambda
  
  # Réplicas brutas
  if (!is.na(mu) && is.finite(mu) && mu > 0) {
    r_raw <- ceiling(l_t / (mu * target_util))
  } else {
    r_raw <- min_replicas
  }
  
  # Histeresis (decide si realmente se escalará)
  scale_up   <- r_raw >  replicas_prev * (1 + delta_up)
  scale_down <- r_raw <  replicas_prev * (1 - delta_down)
  
  if (scale_up) {
    replicas_new <- min(replicas_prev + max_step, r_raw)
  } else if (scale_down) {
    replicas_new <- max(replicas_prev - max_step, r_raw)
  } else {
    replicas_new <- replicas_prev
  }
  
  # garantiza al menos min_replicas
  replicas_new <- max(replicas_new, min_replicas)
  if (replicas_new != replicas_prev) {
    patch <- list(spec = list(replicas = replicas_new))
    res_patch <- PATCH(
      url = deployment_url,
      add_headers(Authorization = paste("Bearer", token),
                  `Content-Type` = "application/strategic-merge-patch+json"),
      config(cainfo = ca_cert),
      body = toJSON(patch, auto_unbox = TRUE)
    )
    if (status_code(res_patch) %in% c(200,201)) {
      cat(sprintf("%d -> %d (EMA λ=%.1f)\n", replicas_prev, replicas_new, l_t))
    } else {
      cat("~ Error al escalar; código:", status_code(res_patch), "\n")
    }
  }else{
    cat(sprintf("Réplicas estables en %d (EMA λ=%.1f)\n", replicas_prev, l_t))
  }
  
  # Actualizar estado para siguiente iteración y guardar historial de replicas_new
  l_prev <- l_t
  replicas_prev <- replicas_new
  
  # Espera antes de la siguiente iteración
  Sys.sleep(interval)
}


  
# Métricas finales

total_req_f <- query_prometheus('sum(nginx_http_requests_total)')
total_req <- total_req_f - total_req_i
  
deploy <- GET(deployment_url, add_headers(Authorization = paste("Bearer", token)), config(cainfo = ca_cert))
stop_for_status(deploy)
final_replicas <- content(deploy, as = "parsed")$spec$replicas


###########################################
# Filtrar datos excluyendo el calentamiento#
###########################################

# Función para eliminar outliers usando IQR
remove_outliers <- function(x) {
  qnt <- quantile(x, probs=c(.25, .75), na.rm = TRUE)
  H <- 1.5 * IQR(x, na.rm = TRUE)
  y <- x
  y[x < (qnt[1] - H)] <- NA
  y[x > (qnt[2] + H)] <- NA
  return(y)
}

# Índices después del período de calentamiento
valid_indices <- which(data$timestamp >= warmup_period_secs)

# Extraer datos válidos (después del período de calentamiento)
valid_data <- list()
for (metric in names(data)) {
  if (metric != "timestamp") {
    # Obtener solo datos después del período de calentamiento
    valid_values <- data[[metric]][valid_indices]
    
    # Eliminar outliers para métricas numéricas (excepto replicas_history que es entero)
    if (metric != "replicas_history") {
      valid_values <- remove_outliers(valid_values)
    }
    
    valid_data[[metric]] <- valid_values
  }
}


#######################
# Imprimir resultados #
#######################

cat("\n===== Resumen de Métricas (Excluyendo Período de Calentamiento y Outliers) =====\n")
cat("λ observado (req/s - sistema):", round(mean(valid_data$lambda, na.rm = TRUE),2), "\n")
cat("throughput observado (req/s - /pod):", round(mean(valid_data$throughput, na.rm = TRUE),6), "\n")
cat("Utilización (ρ - sistema):", round(mean(valid_data$utilization, na.rm = TRUE),2), "\n")
cat("Tiempo medio por respuesta (s/res):", round(mean(valid_data$response_avg_rate, na.rm = TRUE),4), "\n")
cat("Total peticiones:", total_req, "\n")
cat("Réplicas iniciales:", initial_replicas, "\n")
cat("Réplicas finales:", final_replicas, "\n")
cat("Réplicas desviación estandar:", sd(valid_data$replicas_history, na.rm = TRUE), "\n")
cat("# Eventos de escalado:", events, "\n")
cat("Longitud media de cola:", round(mean(valid_data$queue_avg, na.rm = TRUE),2), "\n")
cat("Máx. cola:", round(max(valid_data$queue_max, na.rm = TRUE),2), "\n")
cat("Conexiones activas:", round(mean(valid_data$active_conn, na.rm = TRUE),2), "\n")
cat("GC dur 75 (s):", round(mean(valid_data$gc_dur_p75, na.rm = TRUE),6), "\n")
cat("Heap memory (%):", round(mean(valid_data$heap_ratio, na.rm = TRUE)*100,6), "\n")

# También mostrar estadísticas completas para comparación
cat("\n===== Resumen de Métricas (Todos los datos, incluyendo calentamiento) =====\n")
cat("λ observado (req/s - sistema):", round(mean(data$lambda, na.rm = TRUE),2), "\n")
cat("throughput observado (req/s - /pod):", round(mean(data$throughput, na.rm = TRUE),6), "\n")
cat("Utilización (ρ - sistema):", round(mean(data$utilization, na.rm = TRUE),2), "\n")
cat("Tiempo medio por respuesta (s/res):", round(mean(data$response_avg_rate, na.rm = TRUE),4), "\n")



