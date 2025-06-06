#!/bin/bash
# Instalador para Atenea AI Assistant
# Para repositorio con estructura:
#   atenea/
#     ├── app.py
#     └── templates/
#           ├── index.html
#           └── response.html

echo "⚡ Instalando Atenea AI Assistant..."
echo "------------------------------------"

# 1. Verificar estructura de archivos
echo "🔍 Verificando estructura del repositorio..."
if [ ! -f "app.py" ]; then
    echo "❌ Error: No se encuentra app.py en la raíz del proyecto"
    exit 1
fi

if [ ! -d "templates" ]; then
    echo "❌ Error: No se encuentra el directorio templates/"
    exit 1
fi

if [ ! -f "templates/index.html" ] || [ ! -f "templates/response.html" ]; then
    echo "❌ Error: Faltan archivos HTML en templates/"
    exit 1
fi

# 2. Instalar dependencias del sistema
echo "🛠️  Instalando dependencias del sistema..."
sudo apt update
sudo apt install -y python3 python3-pip python3-venv curl

# 3. Instalar Ollama
echo "🦙 Instalando Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# 4. Crear y activar entorno virtual
echo "🐍 Configurando entorno virtual Python..."
python3 -m venv .venv
source .venv/bin/activate

# 5. Instalar dependencias de Python
echo "📦 Instalando dependencias Python..."
pip install --upgrade pip
pip install flask ollama

# 6. Crear script de inicio
echo "🚀 Creando script de inicio 'start_atenea.sh'..."
cat > start_atenea.sh << 'EOL'
#!/bin/bash
# Script para iniciar Atenea AI Assistant

# Iniciar Ollama en segundo plano
echo "🦙 Iniciando Ollama en segundo plano..."
ollama serve > /dev/null 2>&1 &
OLLAMA_PID=$!

# Esperar que Ollama esté listo
sleep 3

# Activar entorno virtual
source .venv/bin/activate

# Iniciar aplicación
echo "🌐 Iniciando servidor web..."
echo "========================================"
echo "  ACCEDE A LA APLICACIÓN EN TU NAVEGADOR"
echo "  http://localhost:5000"
echo "========================================"
python app.py

# Detener Ollama al salir
echo "🛑 Deteniendo Ollama..."
kill $OLLAMA_PID
EOL

chmod +x start_atenea.sh

# 7. Descargar modelo predeterminado (opcional)
echo "📥 ¿Deseas descargar un modelo predeterminado? [s/N]"
read -r response
if [[ "$response" =~ ^([sS][iYí]?|[sS])$ ]]; then
    echo "1. llama3 (8B - Recomendado para la mayoría de sistemas)"
    echo "2. mistral (7B - Buen equilibrio entre rendimiento y calidad)"
    echo "3. phi3 (3.8B - Ligero, bueno para sistemas con pocos recursos)"
    echo "4. gemma (2B - Muy ligero, para sistemas antiguos)"
    echo "5. No descargar ahora"
    echo "Selecciona un modelo (1-5): "
    read -r model_choice
    
    case $model_choice in
        1)
            ollama pull llama3
            ;;
        2)
            ollama pull mistral
            ;;
        3)
            ollama pull phi3
            ;;
        4)
            ollama pull gemma
            ;;
        *)
            echo "⏭️ Saltando descarga de modelo"
            ;;
    esac
fi

# 8. Crear acceso directo (opcional)
echo "🔗 ¿Crear acceso directo en el escritorio? [s/N]"
read -r shortcut_response
if [[ "$shortcut_response" =~ ^([sS][iYí]?|[sS])$ ]]; then
    cat > ~/Desktop/Atenea.desktop << 'EOL'
[Desktop Entry]
Name=Atenea AI Assistant
Exec=sh -c "cd '$PWD' && ./start_atenea.sh"
Terminal=true
Type=Application
Icon=system-run
Comment=Asistente de IA local con Ollama
Categories=Utility;Application;
EOL
    chmod +x ~/Desktop/Atenea.desktop
    echo "✅ Acceso directo creado en el escritorio"
fi

echo "✅ Instalación completada!"
echo "================================================"
echo "Para iniciar Atenea:"
echo "  ./start_atenea.sh"
echo ""
echo "Para actualizar en el futuro:"
echo "  1. git pull"
echo "  2. source .venv/bin/activate"
echo "  3. pip install -U -r requirements.txt"
echo "================================================"

# Crear archivo requirements.txt
echo "flask" > requirements.txt
echo "ollama" >> requirements.txt
