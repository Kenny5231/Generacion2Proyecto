#!/usr/bin/env bash
# update.sh - Actualizacion controlada de Gitea (solo la imagen rootless, solo este proyecto).
# No hay actualizaciones automaticas: la version nueva se indica de forma explicita.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/update.sh [--version X.Y.Z] [--yes]
  --version X.Y.Z   Version nueva (si se omite, se pregunta). Ejemplo: 28.3.1
  --yes             Acepta la confirmacion simple (NO omite la confirmacion fuerte de un salto de version mayor).

Pasos: validar -> descargar imagen rootless -> avisos -> respaldo previo -> cambiar GITEA_VERSION
       -> validar Compose -> recrear SOLO Gitea -> comprobar funcionamiento.
No se borran volumenes ni datos. Volver a una version anterior exige restaurar un respaldo compatible.
EOF
}

NEW_VERSION=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) [[ $# -ge 2 ]] || die "--version requiere un valor."; NEW_VERSION=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done

init_context

BACKUP_PATH=""
OLD_VERSION=""

recovery_help() {
  cat <<EOF

=== PROCEDIMIENTO DE RECUPERACION ===
Version anterior: ${OLD_VERSION:-desconocida} | Respaldo previo: ${BACKUP_PATH:-no creado}
1. Revise los registros:
     docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml logs --tail 100 gitea
2. Si no se resuelve, restaure el respaldo previo (esto devuelve datos Y version):
     $COMMON_DIR/restore.sh --use-backup-version ${BACKUP_PATH:-<RESPALDO.tar.gz>}
Importante: no cambie GITEA_VERSION a una version anterior sin restaurar el respaldo:
Gitea puede migrar el esquema de la base de datos y un downgrade NO es seguro por si solo.
EOF
}

main() {
  need_cmd docker
  [[ -f $INSTALL_DIR/compose.yaml && -f $INSTALL_DIR/.env ]] || die "No hay instalacion en $INSTALL_DIR."
  validate_config || die "El .env actual no es valido."
  OLD_VERSION=$GITEA_VERSION

  section "Version actual"
  info "Configurada: $OLD_VERSION (imagen $(image_ref "$OLD_VERSION"))"
  if container_running; then
    info "En ejecucion: $(dc exec -T gitea gitea --version 2>/dev/null | sed -n '1p' || echo 'no disponible')"
  else
    warn "Gitea no esta en ejecucion ahora mismo."
  fi

  if [[ -z $NEW_VERSION ]]; then
    NEW_VERSION=$(ask_value "Version nueva de Gitea (X.Y.Z, p. ej. 28.3.1)" "")
  fi
  is_version "$NEW_VERSION" || die "Version invalida: '$NEW_VERSION'. Use el formato X.Y.Z."
  if [[ $NEW_VERSION == "$OLD_VERSION" ]]; then
    ok "Ya esta configurada la version $NEW_VERSION. Nada que hacer."
    exit 0
  fi
  if ! version_gt "$NEW_VERSION" "$OLD_VERSION"; then
    die "$NEW_VERSION es anterior a $OLD_VERSION. Un downgrade no es seguro sin restaurar un respaldo compatible (scripts/restore.sh --use-backup-version)."
  fi

  section "Comprobando imagen rootless"
  local ref
  ref=$(image_ref "$NEW_VERSION")
  docker pull "$ref" || die "No se pudo descargar $ref. Verifique que la version existe: https://hub.docker.com/r/gitea/gitea/tags"
  ok "Imagen disponible: $ref"

  section "Advertencias"
  local major_change=0
  [[ $(major_of "$NEW_VERSION") == "$(major_of "$OLD_VERSION")" ]] || major_change=1
  cat <<EOF
- Gitea puede migrar el esquema de la base de datos al iniciar; despues no se puede volver
  atras sin restaurar un respaldo.
- Lea las notas de la version antes de continuar: https://github.com/go-gitea/gitea/releases
  y https://blog.gitea.com/ (cambios incompatibles de configuracion o comportamiento).
- Se actualiza solo la imagen (${IMAGE_REPO}:<version>${IMAGE_SUFFIX}); nunca se cambia entre rootless y rootful.
EOF
  if [[ $major_change -eq 1 ]]; then
    warn "SALTO DE VERSION MAYOR: $OLD_VERSION -> $NEW_VERSION. Revise las notas con especial cuidado."
    confirm_phrase "ACTUALIZAR" "Escriba ACTUALIZAR para continuar con el salto mayor: " || die "Cancelado; no se modifico nada."
  else
    confirm "Actualizar de $OLD_VERSION a $NEW_VERSION?" || die "Cancelado; no se modifico nada."
  fi

  section "Respaldo previo"
  "$COMMON_DIR/backup.sh" --label "pre-update-$OLD_VERSION" || die "El respaldo previo fallo; no se actualiza."
  BACKUP_PATH=$({ ls -1t -- "$BACKUP_DIR"/*-pre-update-"$OLD_VERSION".tar.gz 2>/dev/null || true; } | sed -n '1p')
  [[ -n $BACKUP_PATH ]] || die "No se localizo el respaldo previo recien creado."
  ok "Respaldo previo: $BACKUP_PATH"

  section "Actualizacion"
  local schema_before schema_after running_now
  schema_before=$(db_schema_version)
  trap 'recovery_help' ERR
  env_set "$INSTALL_DIR/.env" GITEA_VERSION "$NEW_VERSION"
  GITEA_VERSION=$NEW_VERSION
  dc config -q
  ok "Compose valido con GITEA_VERSION=$NEW_VERSION"
  info "Recreando unicamente el servicio gitea..."
  dc up -d gitea
  trap - ERR
  # Una respuesta HTTP no demuestra que la migracion de datos termino bien: se comprueba cada etapa por separado.
  local failed=0
  if wait_for_healthy 300; then
    ok "Healthcheck de Docker: healthy."
  else
    fail "El healthcheck de Docker no llego a 'healthy' (estado: $(container_health))."
    failed=1
  fi
  if [[ $failed -eq 0 ]]; then
    running_now=$(running_gitea_version)
    if [[ $running_now == "$NEW_VERSION" && $(container_image) == "$(image_ref "$NEW_VERSION")" ]]; then
      ok "Se esta ejecutando la version nueva: Gitea $running_now (imagen $(container_image))."
    else
      fail "La version en ejecucion ('${running_now:-desconocida}', imagen '$(container_image)') no es la solicitada ($NEW_VERSION)."
      failed=1
    fi
  fi
  if [[ $failed -eq 0 ]]; then
    if as_data_owner test -f "$(gitea_db_path)"; then
      if sqlite_integrity_ok "$(gitea_db_path)"; then
        ok "Base de datos SQLite: integrity_check correcto."
      else
        fail "La base de datos NO supera integrity_check tras la actualizacion."
        failed=1
      fi
      schema_after=$(db_schema_version)
      if [[ -n $schema_before && -n $schema_after ]]; then
        if (( schema_after > schema_before )); then
          ok "Esquema de la base de datos migrado: version $schema_before -> $schema_after."
        elif (( schema_after == schema_before )); then
          ok "Esquema de la base de datos sin cambios (version $schema_after): esta version no requeria migracion."
        else
          fail "El esquema de la base de datos retrocedio ($schema_before -> $schema_after)."
          failed=1
        fi
      else
        warn "No se pudo comparar la version del esquema de la base de datos (antes: ${schema_before:-?}, despues: ${schema_after:-?})."
      fi
    else
      info "Aun no hay base de datos (asistente pendiente): se omite la comprobacion de migracion."
    fi
    if installer_locked && ! dc exec -T gitea gitea -c /etc/gitea/app.ini admin user list >/dev/null 2>&1; then
      fail "Gitea no pudo listar usuarios con la base de datos actualizada."
      failed=1
    fi
  fi
  if [[ $failed -ne 0 ]]; then
    dc logs --tail 60 gitea || true
    recovery_help
    exit 1
  fi
  wait_for_gitea 60 && ok "Gitea $NEW_VERSION responde en $(local_url)."
  cat <<EOF

Actualizacion completada: $OLD_VERSION -> $NEW_VERSION
Compruebe: $COMMON_DIR/status.sh y $COMMON_DIR/smoke-test.sh
La copia anterior se conserva: respaldo previo $BACKUP_PATH (la imagen anterior $(image_ref "$OLD_VERSION") sigue en Docker).
EOF
}

main
