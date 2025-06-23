import requests
import time
import argparse
import threading
import concurrent.futures

# Contador global de peticiones con bloqueo para evitar condiciones de carrera
class Counter:
    def __init__(self):
        self.value = 0
        self.lock = threading.Lock()
    
    def increment(self):
        with self.lock:
            self.value += 1

# Función simple para enviar una petición
def send_request(url, counter, timeout=1):
    try:
        requests.get(url, timeout=timeout)
        counter.increment()
    except:
        # Contamos la petición aunque falle, ya que lo importante es la carga generada
        counter.increment()

def main():
    parser = argparse.ArgumentParser(description="Test de carga ultra simple")
    parser.add_argument("--url", type=str, default="http://192.168.1.190:30000/",
                        help="URL objetivo")
    parser.add_argument("--potencia", type=int, default=420,
                        help="Potencia de la prueba (nivel de concurrencia)")
    parser.add_argument("--duracion", type=int, default=60,
                        help="Duración de la prueba en segundos")
    args = parser.parse_args()
    
    counter = Counter()
    
    print(f"Iniciando prueba con potencia {args.potencia} contra {args.url}...")
    print(f"Duración: {args.duracion} segundos")
    print("Ejecutando...", flush=True)
    
    # Marca de tiempo inicial
    start_time = time.time()
    end_time = start_time + args.duracion
    
    # Usamos un ThreadPoolExecutor para manejar la concurrencia
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.potencia) as executor:
        futures = []
        
        # Mientras no hayamos alcanzado el tiempo límite
        while time.time() < end_time:
            # Mantenemos la cantidad de trabajos pendientes igual al nivel de potencia
            while len(futures) < args.potencia:
                future = executor.submit(send_request, args.url, counter)
                futures.append(future)
            
            # Eliminamos los trabajos completados
            futures = [f for f in futures if not f.done()]
            
            # Mostramos un contador simple
            elapsed = time.time() - start_time
            if elapsed > 0:
                rate = counter.value / elapsed
                remaining = max(0, args.duracion - elapsed)
                print(f"Tiempo: {elapsed:.1f}/{args.duracion}s | "
                      f"Peticiones: {counter.value} | "
                      f"Tasa: {rate:.1f}/s | "
                      f"Restante: {remaining:.1f}s", end="\r", flush=True)
            
            # Pequeña pausa para no saturar la CPU
            time.sleep(0.1)
    
    # Calculamos el tiempo real que tomó
    total_time = time.time() - start_time
    
    # Resultados finales
    print("\n\n--- RESULTADOS DE LA PRUEBA ---")
    print(f"Potencia utilizada: {args.potencia}")
    print(f"Total de peticiones enviadas: {counter.value}")
    print(f"Duración real: {total_time:.2f} segundos")
    print(f"Tasa promedio: {counter.value / total_time:.2f} peticiones/segundo")
    input("Presiona ENTER para salir...")

if __name__ == "__main__":
    main()

# Start-Process -FilePath "python.exe" -ArgumentList ".\load_test_claude.py" 