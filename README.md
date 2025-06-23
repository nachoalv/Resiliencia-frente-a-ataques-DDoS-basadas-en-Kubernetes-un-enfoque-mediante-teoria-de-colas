# Proyecto TFG - Resiliencia-frente-a-ataques-DDoS-basadas-en-Kubernetes-un-enfoque-mediante-teoria-de-colas
Este TFG estudia la mitigación de ataques DDoS en entornos Kubernetes mediante autoescalado de recursos basado en teoría de colas, evaluando su efectividad mediante pruebas realizadas en entornos controlados, tanto locales como cloud, bajo escenarios de altas cargas.

Este repositorio contiene los archivos relacionados con mi Trabajo de Fin de Grado (TFG) sobre autoescalado y monitorización usando Kubernetes, Prometheus y R.

## Estructura del repositorio

- `/scripts_r/`  
  Contiene los scripts en R para realizar las simulaciones y análisis.

- `/k8s_configs/`  
  Manifiestos YAML para desplegar los distintos componentes en Kubernetes (Nginx, Prometheus, RStudio, etc.).

- `/docs/k3s_install.txt`  
  Instrucciones para instalar y levantar el sistema completo con K3s desde cero.  
  > **Nota:** Si ya tienes K3s instalado, puedes pasar directamente al apartado donde se empieza a usar `kubectl` para omitir la instalación.

- `/resultados/`  
  Resultados de las pruebas y análisis realizados.

- `/load_testers/`  
  Contiene 5 versiones de los load testers en Python que he desarrollado y probado localmente.


## Cómo empezar

1. Si no tienes K3s instalado, sigue las instrucciones en `/docs/k3s_install.txt` para instalarlo y levantar el clúster.  
2. Despliega los recursos en Kubernetes usando los manifiestos YAML que están en `/k8s_configs/`.  
3. Ejecuta los scripts en R que están en `/scripts_r/` para realizar las simulaciones y análisis.  
4. Consulta los resultados obtenidos en `/resultados/`.
5. Para probar los load testers, ejecuta los scripts Python que están en la carpeta `/load_testers/`.

---

Si tienes cualquier duda, puedes abrir un issue o contactarme.

---

### Licencia

Este proyecto está bajo la licencia [Creative Commons Zero v1.0 Universal (CC0)](https://creativecommons.org/publicdomain/zero/1.0/),  
lo que significa que se renuncia a todos los derechos y el trabajo queda en dominio público para el uso libre por cualquier persona.

