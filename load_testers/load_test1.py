import requests
import time
import argparse
import concurrent.futures
import numpy as np  # Para calcular percentiles

def send_request(url):
    try:
        start = time.time()
        response = requests.get(url)
        end = time.time()
        return end - start, response.status_code
    except Exception as e:
        return None, None

def main():
    parser = argparse.ArgumentParser(description="Generador de carga simple")
    parser.add_argument("--url", type=str, default="http://192.168.1.190:30000/",
                        help="URL a la que se enviarán las solicitudes")
    parser.add_argument("--rps", type=int, default=200,
                        help="Número de solicitudes concurrentes (requests per second)")
    parser.add_argument("--duration", type=int, default=300,
                        help="Duración de la prueba en segundos")
    args = parser.parse_args()
    
    total_requests = 0
    successful_requests = 0
    failures = 0
    total_time = 0.0
    latencies = []

    print(f"Iniciando prueba contra {args.url} durante {args.duration} segundos, enviando {args.rps} solicitudes por segundo...")
    start_time = time.time()
    end_time = start_time + args.duration

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.rps) as executor:
        while time.time() < end_time:
            # Enviar "args.rps" solicitudes concurrentes
            future_requests = [executor.submit(send_request, args.url) for _ in range(args.rps)]
            for future in concurrent.futures.as_completed(future_requests):
                elapsed, status = future.result()
                total_requests += 1
                if elapsed is not None and status == 200:
                    successful_requests += 1
                    total_time += elapsed
                    latencies.append(elapsed)
                else:
                    failures += 1
            # Espera hasta completar 1 segundo
            time.sleep(1)

    duration = time.time() - start_time
    error_rate = (failures / total_requests) * 100 if total_requests > 0 else 0
    avg_latency = np.mean(latencies) if latencies else 0
    p95_latency = np.percentile(latencies, 95) if latencies else 0
    p99_latency = np.percentile(latencies, 99) if latencies else 0

    print("------------------------------------------------------")
    print(f"Total de solicitudes enviadas: {total_requests}")
    print(f"Solicitudes exitosas: {successful_requests}")
    print(f"Fallas: {failures}")
    print(f"Tasa de error: {error_rate:.2f}%")
    print(f"Duración total de la prueba: {duration:.2f} segundos")
    if successful_requests > 0:
        print(f"Tiempo de respuesta promedio: {avg_latency:.4f} segundos")
        print(f"P95 de latencia: {p95_latency:.4f} segundos")
        print(f"P99 de latencia: {p99_latency:.4f} segundos")

if __name__ == "__main__":
    main()

# Use examples:
# python load_test.py --url http://192.168.1.35:30000/ --rps 20 --duration 60
# python load_test.py --url http://192.168.1.35:30000/ --rps 100 --duration 60
# python load_test.py --url http://192.168.1.35:30000/ --rps 1000 --duration 60


# freeze requirements on terminal:
# pip freeze > requirements.txt
