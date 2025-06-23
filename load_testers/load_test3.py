import asyncio
import httpx
import time

async def send_request(client, url):
    """Envía una solicitud HTTP GET al servidor."""
    try:
        response = await client.get(url)
        return response.status_code
    except Exception as e:
        print(f"Error: {e}")
        return None

async def load_test(url, max_rps, step, duration):
    """
    Realiza un test de carga incremental.
    
    Args:
        url (str): URL del servidor a probar.
        max_rps (int): Máximo de peticiones por segundo.
        step (int): Incremento de peticiones por segundo en cada paso.
        duration (int): Duración de cada paso en segundos.
    """
    async with httpx.AsyncClient() as client:
        for rps in range(100, max_rps + 1, step):
            print(f"Probando con {rps} peticiones/segundo...")
            tasks = []
            start_time = time.time()

            for _ in range(rps * duration):
                tasks.append(send_request(client, url))
                await asyncio.sleep(1 / rps)  # Controla la tasa de peticiones

            responses = await asyncio.gather(*tasks, return_exceptions=True)
            success_count = sum(1 for r in responses if r == 200)
            fail_count = len(responses) - success_count

            elapsed_time = time.time() - start_time
            print(f"RPS: {rps}, Éxitos: {success_count}, Fallos: {fail_count}, Tiempo: {elapsed_time:.2f}s")

            if fail_count > 0:
                print("El servidor no pudo manejar la carga actual. Finalizando prueba.")
                break

if __name__ == "__main__":
    # Configuración del test
    URL = "http://192.168.1.190:30000/"  # Cambia esto por la URL de tu servidor
    MAX_RPS = 400  # Máximo de peticiones por segundo
    STEP = 50  # Incremento de peticiones por segundo
    DURATION = 30  # Duración de cada paso en segundos

    asyncio.run(load_test(URL, MAX_RPS, STEP, DURATION))