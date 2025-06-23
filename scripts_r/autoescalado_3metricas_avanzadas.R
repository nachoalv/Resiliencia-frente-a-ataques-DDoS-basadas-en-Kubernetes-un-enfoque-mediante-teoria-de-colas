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
duration_secs <- 320  # Duración total en segundos
interval <- 15         # Intervalo entre iteraciones
start_time <- Sys.time()
events <- 0
warmup_period_secs <- 60  # Período de calentamiento de 60 segundos

# Parámetros de escalado avanzado
min_replicas <- 2
max_replicas <- 20
target_util <- 0.75    # Objetivo de utilización
alpha <- 0.4           # Peso EMA para λ suavizada
max_step <- 3          # Máx. cambio de réplicas por iteración
mu <- 100              # Mu máximo del sistema

# Parámetros de estabilización
min_stabilization_time <- 120  # Tiempo mínimo entre escalados (2 minutos)
scale_cooldown_time <- 90       # Período de enfriamiento después de un escalado
stability_window <- 60          # Ventana para verificar estabilidad después del escalado

# Umbrales de escalado
queue_scale_threshold <- 30     # Umbral de longitud de cola para escalado
queue_high_threshold <- 50      # Umbral alto de cola
active_conn_threshold <- 250    # Umbral de conexiones activas para escalado
active_conn_high_threshold <- 400  # Umbral alto de conexiones activas
throughput_scale_util <- 0.85   # Umbral de throughput para escalado
utilization_scale_up <- 0.85    # Umbral de utilización para escalar hacia arriba
utilization_scale_down <- 0.6   # Umbral de utilización para escalar hacia abajo

# Variables de control de escalado
last_scale_time <- Sys.time() - as.difftime(min_stabilization_time, units = "secs")
last_scale_action <- 0  # 0: ninguno, 1: scale up, -1: scale down
last_scale_replicas <- min_replicas
scaling_stability_checks <- list()

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

# Métricas iniciales
deploy <- GET(deployment_url, add_headers(Authorization = paste("Bearer", token)), config(cainfo = ca_cert))
stop_for_status(deploy)
replicas_prev <- content(deploy, as="parsed")$spec$replicas
initial_replicas <- replicas_prev
last_replicas <- replicas_prev

lambda_init <- query_prometheus('sum(rate(nginx_http_requests_total[1m]))')
l_prev <- ifelse(is.na(lambda_init), 0, lambda_init)

total_req_i <- query_prometheus('sum(nginx_http_requests_total)')

# Función para verificar si es seguro escalar
is_safe_to_scale <- function(current_time) {
  # Verificar tiempo mínimo entre escalados
  time_since_last_scale <- as.numeric(difftime(current_time, last_scale_time, units = "secs"))
  
  if (time_since_last_scale < min_stabilization_time) {
    cat("[/] No ha pasado suficiente tiempo desde el último escalado\n")
    return(FALSE)
  }
  
  return(TRUE)
}

# Función para verificar estabilidad post-escalado
check_scaling_stability <- function(replicas, lambda, throughput, utilization) {
  scaling_stability_checks <<- c(scaling_stability_checks, list(
    list(
      replicas = replicas, 
      lambda = lambda, 
      throughput = throughput, 
      utilization = utilization
    )
  ))
  
  # Mantener solo los checks de la ventana de estabilidad
  if (length(scaling_stability_checks) > (stability_window / interval)) {
    scaling_stability_checks <<- scaling_stability_checks[-(1:1)]
  }
  
  # Si tenemos suficientes checks, analizar estabilidad
  if (length(scaling_stability_checks) > 2) {
    # Calcular varianza de métricas
    lambdas <- sapply(scaling_stability_checks, `[[`, "lambda")
    throughputs <- sapply(scaling_stability_checks, `[[`, "throughput")
    utilizations <- sapply(scaling_stability_checks, `[[`, "utilization")
    
    # Criterios de estabilidad (varianza baja)
    lambda_stable <- sd(lambdas, na.rm = TRUE) / mean(lambdas, na.rm = TRUE) < 0.2
    throughput_stable <- sd(throughputs, na.rm = TRUE) / mean(throughputs, na.rm = TRUE) < 0.2
    utilization_stable <- sd(utilizations, na.rm = TRUE) < 0.1
    
    return(lambda_stable && throughput_stable && utilization_stable)
  }
  
  # Si no hay suficientes checks, asumir estable
  return(TRUE)
}

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
  
  # Obtener métricas
  deploy <- GET(deployment_url, add_headers(Authorization = paste("Bearer", token)), config(cainfo = ca_cert))
  stop_for_status(deploy)
  replicas_deploy <- content(deploy, as = "parsed")$spec$replicas
  
  # Métricas de rendimiento
  lambda <- query_prometheus('sum(rate(nginx_http_requests_total[1m]))')
  throughput_global <- query_prometheus('sum(rate(nginx_http_response_count_total[1m]))')
  throughput <- ifelse(is.na(throughput_global) || throughput_global <= 0, NA_real_, throughput_global/replicas_deploy)
  utilization <- lambda / (replicas_deploy * mu)
  
  # Métricas adicionales
  queue_avg <- query_prometheus('avg(nginx_connections_waiting)')
  queue_max <- query_prometheus('max(nginx_connections_waiting)')
  active_conn_total <- query_prometheus('sum(nginx_connections_active)')
  active_conn <- active_conn_total / replicas_deploy
  response_avg_rate <- query_prometheus('sum(rate(nginx_http_response_time_seconds_sum[1m])) / sum(rate(nginx_http_response_time_seconds_count[1m]))')
  
  cat("λ: ", lambda, "	|	μ: ", mu, "	|	throughput: ", throughput, "	|	ρ: ", utilization, "\n")
  cat("Cola promedio: ", queue_avg, "	|	Cola máxima: ", queue_max, "	|	Conexiones activas: ", active_conn, "\n")
  
  # Guardar historial de métricas
  data$timestamp        <- c(data$timestamp, elapsed_time)
  data$lambda           <- c(data$lambda, lambda)
  data$throughput       <- c(data$throughput, throughput)
  data$utilization      <- c(data$utilization, utilization)
  data$response_avg_rate<- c(data$response_avg_rate, response_avg_rate)
  data$queue_avg        <- c(data$queue_avg, queue_avg)
  data$queue_max        <- c(data$queue_max, queue_max)
  data$active_conn      <- c(data$active_conn, active_conn)
  data$replicas_history <- c(data$replicas_history, replicas_deploy)
  
  # EMA de λ para suavizar
  l_t <- alpha * l_prev + (1 - alpha) * lambda
  
  # Decisión de escalado multi-factor
  scale_decision <- 0  # 0: no cambiar, 1: escalar arriba, -1: escalar abajo
  scale_reasons <- c()
  
  # Verificaciones para escalar hacia arriba
  scale_up_conditions <- c(
    utilization > utilization_scale_up,
    !is.na(queue_avg) && queue_avg > queue_scale_threshold,
    !is.na(queue_max) && queue_max > queue_high_threshold,
    !is.na(active_conn) && active_conn > active_conn_threshold,
    !is.na(throughput) && throughput > (mu * throughput_scale_util)
  )
  
  # Verificaciones para escalar hacia abajo
  scale_down_conditions <- c(
    utilization < utilization_scale_down,
    !is.na(queue_avg) && queue_avg < (queue_scale_threshold * 0.5),
    !is.na(active_conn) && active_conn < (active_conn_threshold * 0.5)
  )
  
  # Decisión de escalado
  if (any(scale_up_conditions) && is.safe_to_scale(current_time)) {
    scale_decision <- 1
    scale_reasons <- c("Alta carga")
  } else if (any(scale_down_conditions) && is.safe_to_scale(current_time)) {
    # Solo escalar hacia abajo si hay estabilidad
    if (check_scaling_stability(replicas_deploy, l_t, throughput, utilization)) {
      scale_decision <- -1
      scale_reasons <- c("Baja carga")
    }
  }
  
  # Calcular nuevas réplicas
  replicas_new <- replicas_prev
  
  if (scale_decision == 1) {
    # Escalar hacia arriba
    replicas_new <- min(replicas_prev + max_step, max_replicas)
    cat("[+] Escalando hacia arriba. Razones:", paste(scale_reasons, collapse = ", "), "\n")
    last_scale_action <- 1
    last_scale_replicas <- replicas_new
    last_scale_time <- current_time
  } else if (scale_decision == -1) {
    # Escalar hacia abajo
    replicas_new <- max(replicas_prev - max_step, min_replicas)
    cat("[-] Escalando hacia abajo. Razones:", paste(scale_reasons, collapse = ", "), "\n")
    last_scale_action <- -1
    last_scale_replicas <- replicas_new
    last_scale_time <- current_time
  }
  
  # Actualizar réplicas si es necesario
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
      events <- events + 1
    } else {
      cat("~ Error al escalar; código:", status_code(res_patch), "\n")
    }
  } else {
    cat(sprintf("Réplicas estables en %d (EMA λ=%.1f)\n", replicas_prev, l_t))
  }
  
  # Actualizar estado para siguiente iteración
  l_prev <- l_t
  replicas_prev <- replicas_new
  last_replicas <- replicas_new
  
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

# También mostrar estadísticas completas para comparación
cat("\n===== Resumen de Métricas (Todos los datos, incluyendo calentamiento) =====\n")
cat("λ observado (req/s - sistema):", round(mean(data$lambda, na.rm = TRUE),2), "\n")
cat("throughput observado (req/s - /pod):", round(mean(data$throughput, na.rm = TRUE),6), "\n")
cat("Utilización (ρ - sistema):", round(mean(data$utilization, na.rm = TRUE),2), "\n")
cat("Tiempo medio por respuesta (s/res):", round(mean(data$response_avg_rate, na.rm = TRUE),4), "\n")