library(httr)
library(jsonlite)

# Configuración Prometheus
prom_url <- "http://prometheus.monitoring.svc.cluster.local:9090"
query_prometheus <- function(q) {
  res <- GET(paste0(prom_url, "/api/v1/query"), query = list(query = q))
  stop_for_status(res)
  dat <- content(res, as = "parsed")
  if (dat$status != "success" || length(dat$data$result) == 0) return(NA_real_)
  as.numeric(dat$data$result[[1]]$value[2])
}

# Inicialización
mu_log <- list()

# Número de réplicas
replicas_deploy <- 2

# Duración del bucle (en segundos)
tiempo_total <- 100
intervalo <- 5  # tiempo entre muestras

total_req_i <- query_prometheus('sum(nginx_http_requests_total)')

# Bucle de muestreo
for (i in seq(1, tiempo_total, by = intervalo)) {
  # Timestamp actual
  timestamp <- Sys.time()
  
  lambda <- query_prometheus('sum(rate(nginx_http_requests_total[1m]))')
  
  # 4) Estimación de μ_total y por réplica
  mu_total <- query_prometheus('sum(rate(nginx_http_response_count_total[1m]))')
  mu <- if (!is.na(mu_total) && replicas_deploy > 0) mu_total / replicas_deploy else NA_real_
  
  # Guardar en lista
  mu_log[[length(mu_log) + 1]] <- list(
    time = timestamp,
    lambda = lambda,
    mu_total = mu_total,
    mu = mu
  )
  
  # Log en consola
  cat(sprintf("[%s] λ: %.2f | μ_total: %.2f | μ/replica: %.2f\n",
              format(timestamp, "%H:%M:%S"),
              lambda, mu_total, mu))
  
  # Esperar al siguiente ciclo
  Sys.sleep(intervalo)
}

total_req_f <- query_prometheus('sum(nginx_http_requests_total)')
total_req <- total_req_f - total_req_i

# Convertir a data.frame para análisis final
mu_df <- do.call(rbind, lapply(mu_log, as.data.frame))

# Filtrar valores válidos
mu_validos <- mu_df[!is.na(mu_df$mu_total), ]

# Obtener el valor máximo (posible μ_total en saturación)
mu_max <- max(mu_validos$mu_total, na.rm = TRUE)

cat("\n=============================\n")
cat("Total peticiones:", total_req, "\n")
cat(sprintf("Valor máximo observado de μ_total ≈ %.2f rps\n", mu_max))
cat(sprintf("μ estimado por réplica ≈ %.2f rps (con %d réplicas)\n", mu_max / replicas_deploy, replicas_deploy))