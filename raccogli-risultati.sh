#!/usr/bin/env bash
# Raccoglie i risultati dei test in un archivio da copiare dal server.
#
# Uso (sul server):
#   ./comune/raccogli-risultati.sh            # solo elenco: stato e peso di ogni esecuzione
#   ./comune/raccogli-risultati.sh archivio   # crea risultati-<host>-<data>.tar.gz
#
# Per ogni test e configurazione (es. test 8 "tp4", test 13 una variante)
# nell'archivio entra solo l'ultima esecuzione completa. Restano fuori:
#   - le esecuzioni fallite o interrotte (vLLM non partito, gradini mancanti);
#   - le esecuzioni complete ma rifatte piu' tardi con la stessa configurazione;
#   - i file inputs.json di AIPerf: il dataset inviato al server, di solito il
#     file piu' pesante, rigenerabile con lo stesso seed e inutile all'analisi.
# Un'esecuzione e' completa se per ogni benchmark AIPerf ha scritto un
# profile_export_aiperf.json per ogni gradino di utenti indicato nel suo log.
#
# Variabili facoltative:
#   LEGGERO=1  esclude anche i *.jsonl (dati grezzi per singola richiesta,
#              telemetria GPU e metriche vLLM campionate): restano riepiloghi,
#              csv, fette da 60 s e log. Senza i jsonl non si possono piu'
#              ricalcolare metriche per turno o per lunghezza del contesto.
#   TUTTE=1    include tutte le esecuzioni complete, non solo l'ultima.
#   FORZA="test-19-guasti-glm/risultati/20261117-101500 ..."
#              include comunque queste cartelle anche se incomplete
#              (es. un test di guasto in cui AIPerf si e' interrotto).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-elenco}"
[[ "$MODE" == "elenco" || "$MODE" == "archivio" ]] || { echo "Uso: $0 [elenco|archivio]" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
EXCL=(--exclude=inputs.json)
[[ "${LEGGERO:-0}" == "1" ]] && EXCL+=(--exclude='*.jsonl')

# Stato di una configurazione: OK, oppure il motivo per cui non e' completa.
stato() {
  local dir="$1" log users attesi trovati n=0 msg=""
  if grep -qs "non e' partito" "$dir/tempi.txt"; then echo "FALLITA (vLLM non partito)"; return; fi
  if [[ -d "$dir/aiperf" ]]; then
    while IFS= read -r log; do
      n=$((n + 1))
      users=$(sed -n 's/^Utenti per gradino: \([0-9,]*\), [0-9]* s per gradino.*/\1/p' "$log" | head -1)
      attesi=$(awk -F, '{print NF}' <<< "$users")
      trovati=$(find "$(dirname "$log")" -name profile_export_aiperf.json | wc -l)
      if [[ -z "$users" ]] || (( trovati < attesi )); then
        msg+=" $(basename "$(dirname "$(dirname "$log")")") ${trovati}/${attesi:-?}"
      fi
    done < <(find "$dir/aiperf" -mindepth 4 -maxdepth 4 -name aiperf.log | sort)
  fi
  if (( n == 0 )); then echo "FALLITA (nessun benchmark)"
  elif [[ -n "$msg" ]]; then echo "INCOMPLETA (gradini:$msg)"
  else echo "OK"; fi
}

# 1. Tutte le configurazioni di tutte le esecuzioni.
#    Una configurazione e' una cartella con dentro "aiperf", oppure con
#    vllm-args.txt / tempi.txt e nessun benchmark sotto (avvio fallito).
: > "$TMP/tutte"
for stampdir in test-*/risultati/*/; do
  stampdir="${stampdir%/}"
  [[ -d "$stampdir" ]] || continue
  test="${stampdir%%/*}"; stamp="${stampdir##*/}"
  { find "$stampdir" -type d -name aiperf -prune -printf '%h\n'
    find "$stampdir" \( -name vllm-args.txt -o -name tempi.txt \) -printf '%h\n'
  } | sort -u | while IFS= read -r cfg; do
    # Cartella che contiene configurazioni con benchmark (test 5 e 6): non e' una configurazione.
    if [[ ! -d "$cfg/aiperf" && -n "$(find "$cfg" -mindepth 2 -type d -name aiperf -print -quit)" ]]; then
      continue
    fi
    rel="${cfg#"$stampdir"}"; rel="${rel#/}"
    key="$test${rel:+/$rel}"
    peso=$(du -sh "$cfg" | cut -f1)
    utile=$(du -sh "${EXCL[@]}" "$cfg" | cut -f1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$stamp" "$cfg" "$(stato "$cfg")" "$peso" "$utile"
  done >> "$TMP/tutte"
done

# 2. Scelta: l'ultima esecuzione OK per configurazione (o tutte con TUTTE=1),
#    piu' le cartelle indicate in FORZA.
sort -t$'\t' -k1,1 -k2,2r "$TMP/tutte" | awk -F'\t' -v tutte="${TUTTE:-0}" -v forza=" ${FORZA:-} " '
  { sel = 0
    if ($4 == "OK" && (tutte == "1" || !($1 in presa))) { sel = 1; presa[$1] = 1 }
    if (index(forza, " " $3 " ") || index(forza, " " $3 "/ ")) sel = 1
    split($3, p, "/"); stampdir = p[1] "/" p[2] "/" p[3]
    print sel "\t" stampdir "\t" $0 }' > "$TMP/scelte"

# 3. Elenco.
ultima01=$(ls -d test-01-verifica-iniziale/risultati-* 2>/dev/null | sort | tail -1 || true)
{
  printf '%-1s %-52s %-16s %-6s %-6s %s\n' "" "TEST / CONFIGURAZIONE" "ESECUZIONE" "PESO" "UTILE" "STATO"
  sort -t$'\t' -k3,3 -k4,4 "$TMP/scelte" | while IFS=$'\t' read -r sel _ key stamp _ st peso utile; do
    printf '%-1s %-52s %-16s %-6s %-6s %s\n' "$([[ $sel == 1 ]] && echo '*')" "$key" "$stamp" "$peso" "$utile" "$st"
  done
  echo
  echo "* = entra nell'archivio. UTILE = peso senza i file esclusi (${EXCL[*]#--exclude=}), prima della compressione."
  [[ -z "$ultima01" ]] || echo "Test 1: entra $ultima01"
} | tee "$TMP/INDICE.txt"

awk -F'\t' '$1 == 1 { print $5 }' "$TMP/scelte" > "$TMP/cartelle"
if [[ -s "$TMP/cartelle" ]]; then
  echo
  echo "Peso per tipo di file nelle esecuzioni scelte (prima della compressione):"
  while IFS= read -r d; do find "$d" -type f -printf '%s %f\n'; done < "$TMP/cartelle" \
    | sed -E 's/ vllm-test[^ ]*\./ <container>./; s/ (nginx|proxy|router)[^ ]*\.(log|conf)$/ <\1>.\2/' \
    | awk '{ s[$2] += $1; n[$2]++ } END { for (f in s) printf "%10.1f MB %6d file  %s\n", s[f] / 1048576, n[f], f }' \
    | sort -rn | head -20
fi

[[ "$MODE" == "archivio" ]] || { echo; echo "Per creare l'archivio: $0 archivio"; exit 0; }

# 4. Archivio: le configurazioni scelte, piu' i file e la cartella vllm/ che
#    alcuni test salvano al livello dell'esecuzione (tempi, nginx, log vLLM).
awk -F'\t' '$1 == 1 { print $5; print $2 }' "$TMP/scelte" | sort -u | while IFS= read -r d; do
  if grep -qxF "$d" "$TMP/cartelle"; then echo "$d"
  else find "$d" -maxdepth 1 -type f; [[ -d "$d/vllm" ]] && echo "$d/vllm"; fi
done > "$TMP/lista"
[[ -z "$ultima01" ]] || echo "$ultima01" >> "$TMP/lista"
sort -u -o "$TMP/lista" "$TMP/lista"

ARCH="$ROOT/risultati-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$ARCH" "${EXCL[@]}" -C "$ROOT" -T "$TMP/lista" -C "$TMP" INDICE.txt
echo
echo "Archivio: $ARCH ($(du -h "$ARCH" | cut -f1))"
echo "Da estrarre nella cartella dei test sul PC: ricrea test-XX/risultati/<data>/..."
