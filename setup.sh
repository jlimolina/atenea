#!/bin/bash

#-----------------------------------------------------------------------
# Instalador Automático de Producción para "Atenea" v4.0
#
# Prepara un servidor Linux (basado en Debian/Ubuntu), instala todas
# las dependencias, configura Ollama, y despliega la aplicación Flask
# con Gunicorn y Nginx. Es idempotente y seguro de ejecutar.
#-----------------------------------------------------------------------

# Salir inmediatamente si un comando falla para evitar instalaciones parciales.
set -e

echo "--- 🚀 Iniciando el instalador de Producción de Atenea AI 🚀 ---"

# --- PASO 1: Recopilar y confirmar la configuración ---
read -p "Introduce el dominio para tu aplicación (ej. atenea.midominio.com). Pulsa ENTER para usar 'localhost': " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-localhost}

CURRENT_USER=$(whoami)
PROJECT_DIR=$(pwd)

echo "--------------------------------------------------"
echo "Se usará la siguiente configuración para el despliegue:"
echo "Dominio:               $DOMAIN_NAME"
echo "Usuario del servicio:    $CURRENT_USER"
echo "Directorio del proyecto: $PROJECT_DIR"
echo "--------------------------------------------------"
read -p "¿Es correcta esta configuración? (s/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Instalación cancelada por el usuario."
    exit 1
fi

# --- PASO 2: Instalar dependencias del sistema y PPA de Python ---
echo -e "\n--- 📦 Instalando dependencias del sistema y repositorio de Python ---"
sudo apt-get update
sudo apt-get install -y software-properties-common curl
# Añade el PPA "deadsnakes" para poder instalar versiones recientes de Python.
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update
# Instala la versión específica de Python, Nginx y Git.
sudo apt-get install -y python3.11 python3.11-venv nginx git

# --- PASO 3: Instalar y configurar Ollama ---
echo -e "\n--- 🦙 Instalando y configurando Ollama ---"
if command -v ollama &> /dev/null; then
    echo "Ollama ya está instalado. Verificando que el servicio esté activo..."
else
    echo "Ollama no encontrado. Descargando e instalando con el script oficial..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
echo "Asegurando que el servicio de Ollama esté en ejecución y habilitado para el arranque..."
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama

# --- PASO 4: Configurar el entorno de Python ---
echo -e "\n--- 🐍 Configurando el entorno virtual de Python ---"
if [ -d "venv" ]; then
    echo "La carpeta 'venv' ya existe. Omitiendo la creación del entorno."
else
    echo "Creando entorno virtual en 'venv'..."
    python3.11 -m venv venv
fi

echo "Instalando dependencias de Python desde requirements.txt..."
# Se usa la ruta absoluta al pip del venv para garantizar una instalación correcta.
"$PROJECT_DIR/venv/bin/pip" install -r requirements.txt

echo "Entorno de Python configurado."

# --- PASO 5: Configurar el servicio de systemd para Atenea ---
echo -e "\n--- ⚙️ Configurando Gunicorn con systemd para la app Atenea ---"
# Se usa 'cat' con un Here Document (EOF) para crear el archivo de servicio dinámicamente.
cat <<EOF | sudo tee /etc/systemd/system/atenea.service
[Unit]
Description=Gunicorn instance para servir la aplicación Atenea
# Dependencias: No iniciar este servicio hasta que la red y Ollama estén activos.
Requires=ollama.service
After=network.target ollama.service

[Service]
# Ejecuta el servicio como el usuario actual (no como root).
User=$CURRENT_USER
# Permite que Nginx (grupo www-data) acceda al socket para comunicarse.
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PROJECT_DIR/venv/bin"
# Comando para iniciar Gunicorn, con el socket en /run para evitar problemas de permisos.
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind unix:/run/atenea.sock -m 007 --timeout 120 app:app
# Reinicia el servicio automáticamente si falla.
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Iniciando y habilitando el servicio 'atenea'..."
sudo systemctl daemon-reload
sudo systemctl restart atenea
sudo systemctl enable atenea

echo "Servicio de Atenea configurado y en ejecución."

# --- PASO 6: Configurar Nginx como Reverse Proxy ---
echo -e "\n--- 🌐 Configurando Nginx como servidor web (Reverse Proxy) ---"
cat <<EOF | sudo tee /etc/nginx/sites-available/atenea
server {
    listen 80;
    server_name $DOMAIN_NAME;

    # Sirve los archivos estáticos (CSS, JS) directamente para mayor eficiencia.
    location /static {
        alias $PROJECT_DIR/static;
    }

    # Pasa todas las demás peticiones a la aplicación Gunicorn a través del socket.
    location / {
        # Aumentar timeouts para tareas largas de IA.
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        fastcgi_send_timeout 600s;
        fastcgi_read_timeout 600s;

        include proxy_params;
        proxy_pass http://unix:/run/atenea.sock;
    }
}
EOF

echo "Habilitando la configuración del sitio en Nginx..."
# Crea un enlace simbólico para activar la configuración.
sudo ln -s -f /etc/nginx/sites-available/atenea /etc/nginx/sites-enabled/

# Es una buena práctica eliminar la configuración por defecto de Nginx.
if [ -f /etc/nginx/sites-enabled/default ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

echo "Probando la sintaxis de Nginx y reiniciando el servicio..."
sudo nginx -t
sudo systemctl restart nginx

# --- Finalización ---
echo -e "\n--- ✅ ¡Instalación completada! ---"
echo "Tu aplicación Atenea ahora debería estar accesible en: http://$DOMAIN_NAME"
echo "Puedes comprobar el estado de los servicios en cualquier momento con:"
echo "  sudo systemctl status atenea"
echo "  sudo systemctl status ollama"
echo "Para ver los logs de la aplicación en tiempo real, usa:"
echo "  journalctl -u atenea -f"

