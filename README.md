# OpenTopoData Script

Este repositorio contiene un script de instalación y gestión para desplegar OpenTopoData con el dataset Copernicus DEM GLO-30 (resolución 30m, cobertura mundial) usando Docker.

## ¿Qué hace este script?
- Instala los requisitos del sistema (Docker, AWS CLI, curl, git)
- Clona el repositorio oficial de OpenTopoData
- Descarga el dataset Copernicus DEM GLO-30 (~300GB) desde AWS S3
- Crea el archivo de configuración necesario
- Construye y ejecuta el contenedor Docker
- Permite gestionar el servicio (iniciar, detener, ver logs, desinstalar, etc.)

## Uso rápido
```bash
./setup.sh
```
Sigue el menú interactivo para instalar, gestionar o desinstalar OpenTopoData.

## Variables de configuración principales
Puedes modificar estas variables al inicio del script `setup.sh` para personalizar la instalación:

- `REPO_URL`: URL del repositorio de OpenTopoData a clonar.
- `INSTALL_DIR`: Carpeta donde se instalará OpenTopoData y el dataset. Por defecto: `$HOME/opentopodata`.
- `DATASET_NAME`: Nombre del dataset (por defecto: `copernico-ww`).
- `HOST_PORT`: Puerto en el que se expondrá la API (por defecto: `5000`).

También puedes pasar algunos parámetros por línea de comandos:
```bash
./setup.sh --install-dir /ruta/deseada --port 8080
```

## Notas importantes
- Se requieren ~350GB de espacio libre en disco.
- No necesitas una cuenta de AWS para descargar el dataset (es público).
- El contenedor Docker se configura para reiniciarse automáticamente tras un reinicio del sistema.
- El script es interactivo y te pedirá confirmación antes de realizar acciones destructivas.

## Desinstalación
Desde el menú principal, elige la opción "Uninstall everything" para eliminar contenedores, imágenes y (opcionalmente) los datos y la instalación.

---

Para más detalles, revisa y edita el script `setup.sh` según tus necesidades.
