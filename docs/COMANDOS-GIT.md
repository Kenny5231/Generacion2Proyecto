# Comandos Git para el Gitea privado

Todos los comandos se ejecutan en **🪟 PowerShell (Windows)**, salvo que se indique otra cosa.
Con el alias creado por `windows\setup-git.ps1`, la URL de un repositorio es `git-privado:<usuario>/<repositorio>.git`
(el alias ya incluye servidor, puerto y clave). Sin alias: `ssh://git@<equipo>.<tailnet>.ts.net:2222/<usuario>/<repositorio>.git`.

## Configuración inicial (una vez)

```powershell
git config --global user.name  "Su Nombre"
git config --global user.email "su-correo@dominio"
git config --global init.defaultBranch main
powershell -ExecutionPolicy Bypass -File .\windows\setup-git.ps1 -ServerName <equipo>.<tailnet>.ts.net
ssh -T git-privado        # verifique la huella la primera vez; debe decir "successfully authenticated"
```

Registre la clave pública (`~/.ssh/id_ed25519_gitea_privado.pub`) en Gitea: avatar → Configuración → Claves SSH / GPG.
Si usa una frase de contraseña, puede cargar la clave en el agente para no escribirla cada vez:

```powershell
# Una vez, en PowerShell como administrador:
Get-Service ssh-agent | Set-Service -StartupType Manual
# Luego, como usuario normal:
Start-Service ssh-agent
ssh-add $HOME\.ssh\id_ed25519_gitea_privado
```

## Crear un repositorio privado (primera prueba)

1. En Gitea: **+ → Nuevo repositorio**. Todos los repositorios son privados (no se pueden crear públicos).
2. Clonar, crear un archivo, confirmar y subir:

```powershell
git clone git-privado:<usuario>/mi-proyecto.git
cd mi-proyecto
"Hola" | Out-File -Encoding utf8 LEEME.txt
git add LEEME.txt
git commit -m "Primer commit"
git push -u origin HEAD
```

3. Compruebe el archivo en la web y clone de nuevo en otra carpeta para confirmar:

```powershell
cd ..
git clone git-privado:<usuario>/mi-proyecto.git mi-proyecto-copia
Get-Content .\mi-proyecto-copia\LEEME.txt
```

## Subir un proyecto que ya tiene en su equipo

```powershell
cd C:\ruta\de\su\proyecto
git init                                  # solo si aún no es un repositorio
git add .
git commit -m "Importación inicial"
git branch -M main
git remote add origin git-privado:<usuario>/<repositorio>.git      # cree antes el repositorio vacío en Gitea
git push -u origin main
```

Para **cambiar** un proyecto que hoy apunta a GitHub: `git remote set-url origin git-privado:<usuario>/<repositorio>.git`
y luego `git push -u origin --all` y `git push origin --tags`. (Conserva todo el historial.)

## Uso diario

| Acción | Comando |
|---|---|
| Ver estado | `git status` |
| Ver historial | `git log --oneline --graph --decorate -n 20` |
| Traer cambios | `git pull` |
| Subir cambios | `git add . ; git commit -m "mensaje" ; git push` |
| Nueva rama | `git switch -c mi-rama` |
| Cambiar de rama | `git switch main` |
| Subir una rama nueva | `git push -u origin mi-rama` |
| Fusionar | `git switch main ; git merge mi-rama` |
| Etiqueta | `git tag -a v1.0.0 -m "Versión 1.0.0" ; git push origin v1.0.0` |
| Ver remotos | `git remote -v` |
| Deshacer cambios sin confirmar en un archivo | `git restore <archivo>` |
| Clonar | `git clone git-privado:<usuario>/<repositorio>.git` |

(En PowerShell 5.1 encadene comandos con `;`, no con `&&`.)

## Usuarios adicionales

Administración del sitio (avatar → **Administración del sitio → Cuentas de usuario → Crear cuenta de usuario**). El registro abierto está
deshabilitado: solo el administrador crea cuentas. Cada usuario registra su propia clave SSH y debería activar 2FA.

## Verificar la conexión

```powershell
ssh -T git-privado                         # autenticación SSH
ssh -vT git-privado                        # detalle (qué clave se usa, dónde falla)
git ls-remote git-privado:<usuario>/<repositorio>.git     # lectura de un repositorio
```

🐧 En el servidor: `/srv/gitea-privado/scripts/smoke-test.sh` y `/srv/gitea-privado/scripts/status.sh`.

## Huella del servidor SSH

La primera conexión muestra `SHA256:...`. Acéptela solo si coincide con la que aparece en el servidor
(🐧 `/srv/gitea-privado/scripts/status.sh`, sección "Huellas SSH") o con `ssh-keyscan -p 2222 <equipo>.<tailnet>.ts.net | ssh-keygen -lf -`.
Si más adelante SSH avisa `REMOTE HOST IDENTIFICATION HAS CHANGED`, **no lo ignore**: puede ser una reinstalación legítima
(sin restaurar `data/data/ssh`) o un intento de suplantación. Verifique la nueva huella antes de borrar la entrada antigua con
`ssh-keygen -R "[<equipo>.<tailnet>.ts.net]:2222"`.
