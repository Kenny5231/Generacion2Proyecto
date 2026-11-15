#!/usr/bin/env python3
"""tsjson.py - Analisis estructurado (solo lectura) del JSON de Tailscale.

Lee JSON por la entrada estandar y nunca ejecuta ni modifica nada.

Uso:
  tailscale status --json | tsjson.py status state|dns|ip4|certs
  tailscale serve status --json | tsjson.py serve --dns DNS --https-port N \
        --web-port N --ssh-port N --ssh-local-port N

Salida de 'serve' (lineas CLAVE=valor):
  schema=ok | schema=unrecognized (+ reason=...)   codigo de salida 0 | 3
  https=free|ours|foreign      puerto HTTPS de Serve para Gitea
  ssh=free|ours|foreign        puerto TCP de Serve para el SSH de Git
  funnel=none|on               Funnel sobre los puertos de Gitea
  *_detail=...                 descripcion legible de lo encontrado
Si la estructura no se reconoce, el script falla de forma segura (codigo 3) y NO decide nada.
"""
import argparse
import json
import re
import sys

KNOWN_TOP_LEVEL = {"TCP", "Web", "Services", "AllowFunnel", "Foreground", "ETag"}


class Unrecognized(Exception):
    pass


def clean(text, limit=160):
    """Sanea valores externos antes de imprimirlos (sin saltos de linea ni controles)."""
    text = re.sub(r"[^\x20-\x7e]", "?", str(text))
    return text[:limit]


def load(raw):
    if not raw.strip():
        raise Unrecognized("entrada vacia")
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise Unrecognized("JSON invalido: %s" % clean(exc))
    if not isinstance(data, dict):
        raise Unrecognized("la raiz no es un objeto JSON")
    return data


def first_ipv4(values):
    if not isinstance(values, list):
        return ""
    for ip in values:
        if isinstance(ip, str) and re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip):
            return ip
    return ""


def cmd_status(args):
    data = load(sys.stdin.read())
    self_node = data.get("Self")
    if not isinstance(self_node, dict):
        self_node = {}
    if args.field == "state":
        value = data.get("BackendState", "")
    elif args.field == "dns":
        value = self_node.get("DNSName", "")
        if isinstance(value, str):
            value = value.rstrip(".").lower()
    elif args.field == "ip4":
        value = first_ipv4(self_node.get("TailscaleIPs")) or first_ipv4(data.get("TailscaleIPs"))
    else:  # certs: cantidad de dominios HTTPS habilitados
        domains = data.get("CertDomains")
        value = len(domains) if isinstance(domains, list) else 0
    if not isinstance(value, (str, int)):
        raise Unrecognized("campo con tipo inesperado")
    print(clean(value))
    return 0


def proxy_matches(proxy, web_port):
    return isinstance(proxy, str) and proxy.rstrip("/") in (
        "http://127.0.0.1:%d" % web_port,
        "http://localhost:%d" % web_port,
    )


def forward_matches(target, local_port):
    return isinstance(target, str) and target in (
        "127.0.0.1:%d" % local_port,
        "localhost:%d" % local_port,
    )


def classify_https(cfg, dns, port, web_port):
    tcp, web = cfg["TCP"], cfg["Web"]
    entry = tcp.get(str(port))
    host_key = "%s:%d" % (dns, port)
    handlers_cfg = web.get(host_key)
    if entry is None and handlers_cfg is None:
        return "free", "libre"
    if entry is None or handlers_cfg is None:
        return "foreign", "configuracion incompleta o distinta en el puerto %d" % port
    if set(entry.keys()) != {"HTTPS"} or entry.get("HTTPS") is not True:
        return "foreign", "el puerto %d no es un HTTPS simple de Serve" % port
    handlers = handlers_cfg.get("Handlers")
    if not isinstance(handlers, dict):
        raise Unrecognized("Web[%s].Handlers no es un objeto" % clean(host_key))
    if set(handlers.keys()) != {"/"}:
        return "foreign", "rutas publicadas: %s" % clean(", ".join(sorted(handlers.keys())))
    handler = handlers["/"]
    if not isinstance(handler, dict):
        raise Unrecognized("handler '/' con tipo inesperado")
    if set(handler.keys()) == {"Proxy"} and proxy_matches(handler["Proxy"], web_port):
        return "ours", "proxy %s" % clean(handler["Proxy"])
    return "foreign", "destino distinto: %s" % clean(json.dumps(handler, sort_keys=True))


def classify_ssh(cfg, dns, port, local_port):
    tcp, web = cfg["TCP"], cfg["Web"]
    entry = tcp.get(str(port))
    if entry is None:
        if ("%s:%d" % (dns, port)) in web:
            return "foreign", "el puerto %d tiene un servicio web de Serve" % port
        return "free", "libre"
    if set(entry.keys()) == {"TCPForward"} and forward_matches(entry["TCPForward"], local_port):
        return "ours", "tcp-forward %s" % clean(entry["TCPForward"])
    return "foreign", "destino distinto: %s" % clean(json.dumps(entry, sort_keys=True))


def cmd_serve(args):
    data = load(sys.stdin.read())
    unknown = set(data.keys()) - KNOWN_TOP_LEVEL
    if unknown:
        raise Unrecognized("claves de nivel superior desconocidas: %s" % clean(", ".join(sorted(unknown))))
    cfg = {}
    for key in ("TCP", "Web", "AllowFunnel"):
        value = data.get(key) or {}
        if not isinstance(value, dict):
            raise Unrecognized("'%s' no es un objeto" % key)
        cfg[key] = value
    for key in ("TCP", "Web"):
        for name, item in cfg[key].items():
            if not isinstance(item, dict):
                raise Unrecognized("%s[%s] no es un objeto" % (key, clean(name)))
    for name, item in cfg["TCP"].items():
        if not re.fullmatch(r"\d{1,5}", name):
            raise Unrecognized("puerto TCP no numerico: %s" % clean(name))

    dns = args.dns.rstrip(".").lower()
    https, https_detail = classify_https(cfg, dns, args.https_port, args.web_port)
    ssh, ssh_detail = classify_ssh(cfg, dns, args.ssh_port, args.ssh_local_port)
    ours_hostports = {"%s:%d" % (dns, args.https_port), "%s:%d" % (dns, args.ssh_port)}
    funnel_on = sorted(hp for hp, on in cfg["AllowFunnel"].items() if on is True and hp in ours_hostports)
    other_funnel = sorted(hp for hp, on in cfg["AllowFunnel"].items() if on is True and hp not in ours_hostports)

    print("schema=ok")
    print("https=%s" % https)
    print("https_detail=%s" % https_detail)
    print("ssh=%s" % ssh)
    print("ssh_detail=%s" % ssh_detail)
    print("funnel=%s" % ("on" if funnel_on else "none"))
    print("funnel_other=%s" % clean(",".join(other_funnel)))
    print("tcp_ports=%s" % ",".join(sorted(cfg["TCP"].keys(), key=int)))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_status = sub.add_parser("status")
    p_status.add_argument("field", choices=["state", "dns", "ip4", "certs"])
    p_serve = sub.add_parser("serve")
    p_serve.add_argument("--dns", required=True)
    p_serve.add_argument("--https-port", type=int, required=True)
    p_serve.add_argument("--web-port", type=int, required=True)
    p_serve.add_argument("--ssh-port", type=int, required=True)
    p_serve.add_argument("--ssh-local-port", type=int, required=True)
    args = parser.parse_args()
    try:
        return cmd_status(args) if args.command == "status" else cmd_serve(args)
    except Unrecognized as exc:
        print("schema=unrecognized")
        print("reason=%s" % clean(exc))
        return 3


if __name__ == "__main__":
    sys.exit(main())
