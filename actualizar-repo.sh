#!/bin/bash

# --- Script para actualizar el repositorio de Git automáticamente ---

echo "🚀 Iniciando actualización del repositorio..."

# 1. Verificar el estado (opcional, pero bueno para ver qué se sube)
echo "----------------------------------------"
git status
echo "----------------------------------------"

# 2. Preparar todos los archivos modificados y nuevos
echo "➕ Añadiendo todos los archivos al área de preparación (git add .)"
git add .

# 3. Crear el mensaje del commit con la fecha y hora actual
COMMIT_MSG="Actualización del $(date +'%Y-%m-%d a las %H:%M:%S')"
echo "💬 Creando commit con el mensaje: '$COMMIT_MSG'"
git commit -m "$COMMIT_MSG"

# 4. Subir los cambios a GitHub
echo "⬆️ Subiendo cambios al repositorio remoto (git push)..."
git push

echo "✅ ¡Actualización completada!"
