#!/usr/bin/env bash
###############################################################################
#  maj_auto.sh - Mise à jour automatique multi-distributions + logs + mail
#
#  Ce que fait le script :
#    1. Détecte la famille Linux (Debian, RedHat, Arch, SUSE, Alpine)
#    2. Rafraîchit les index de paquets (ex: apt update)
#    3. Liste ce qui est à mettre à jour
#    4. Applique les mises à jour (upgrade)
#    5. Écrit TOUT dans des logs (répertoire créé par le script)
#    6. Génère un récapitulatif (.txt)
#    7. L'envoie par mail avec le sujet :
#         SAUVEGARDE DU JOUR : DD/MM/YYYY - HH:mm:ss
#
#  Utilisation :
#       chmod +x maj_auto.sh
#       sudo ./maj_auto.sh
#
#  Prérequis pour le mail : un MTA/client configuré sur la machine
#  (msmtp, postfix, exim, ssmtp... fournissant "sendmail", ou mutt / mailx).
###############################################################################

# -----------------------------------------------------------------------------
# Options de sécurité du shell
#   -u          : erreur si on utilise une variable non définie (évite les bugs)
#   -o pipefail : un pipe échoue si UNE de ses commandes échoue (pas que la dernière)
# On n'active volontairement PAS "-e" : on veut continuer et logger même si
# une étape échoue, plutôt que de s'arrêter net.
# -----------------------------------------------------------------------------
set -uo pipefail

# Force la langue en "C" pour que les sorties des commandes soient en anglais
# et donc prévisibles lorsqu'on les parse (comptage de paquets, etc.).
export LC_ALL=C

###############################################################################
# 1. CONFIGURATION (à adapter si besoin)
###############################################################################

MAIL_DEST="admin@example.com"           # Destinataire du récapitulatif
MAIL_FROM="maj-auto@$(hostname -f 2>/dev/null || hostname)"  # Expéditeur affiché
LOG_BASE="/var/log/maj_auto"             # Répertoire racine des logs (créé par le script)
RETENTION_JOURS=30                       # Les logs plus vieux que N jours sont supprimés

# Horodatages calculés UNE seule fois pour rester cohérents dans tout le script
DATE_FICHIER="$(date '+%Y%m%d_%H%M%S')"          # ex: 20261005_143012 (pour les noms de fichiers)
DATE_SUJET="$(date '+%d/%m/%Y - %H:%M:%S')"      # ex: 05/10/2026 - 14:30:12 (pour le sujet du mail)

# Dossier dédié à CETTE exécution
RUN_DIR="${LOG_BASE}/${DATE_FICHIER}"

# Fichiers de log (définis ici, créés plus bas)
LOG_GLOBAL="${RUN_DIR}/global.log"               # Journal complet de tout ce qui se passe
LOG_UPDATE="${RUN_DIR}/01_refresh_index.log"     # Sortie brute du rafraîchissement des index
LOG_LISTE="${RUN_DIR}/02_paquets_a_maj.log"      # Liste des paquets à mettre à jour
LOG_UPGRADE="${RUN_DIR}/03_upgrade.log"          # Sortie brute de l'upgrade
RECAP="${RUN_DIR}/RECAPITULATIF.txt"             # Fichier récap envoyé par mail

# Variables remplies pendant l'exécution
FAMILLE=""        # debian | redhat | arch | suse | alpine
DISTRO_NOM=""     # Nom lisible (ex: "Ubuntu 22.04.4 LTS")
NB_A_MAJ=0        # Nombre de paquets à mettre à jour avant l'upgrade
RC_REFRESH=0      # Code retour du rafraîchissement
RC_UPGRADE=0      # Code retour de l'upgrade
REBOOT_NEEDED="non"

###############################################################################
# 2. FONCTIONS UTILITAIRES
###############################################################################

# log "message" : écrit une ligne horodatée à l'écran ET dans le log global.
#   - date '+...'       : horodatage
#   - tee -a            : affiche à l'écran et AJOUTE (-a) au fichier
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_GLOBAL"
}

# run_logged "fichier_log" commande args... :
#   exécute une commande, copie sa sortie (stdout+stderr) dans le fichier donné
#   ET dans le log global, puis renvoie le VRAI code retour de la commande.
run_logged() {
    local fichier="$1"; shift
    log "COMMANDE : $*"
    # 2>&1       : fusionne les erreurs (stderr) avec la sortie normale (stdout)
    # tee -a ... : écrit dans le log spécifique + le log global, et affiche à l'écran
    "$@" 2>&1 | tee -a "$fichier" >> "$LOG_GLOBAL"
    # PIPESTATUS[0] = code retour de la 1ère commande du pipe (notre commande,
    # pas celui de tee). Il faut le lire IMMÉDIATEMENT après le pipe.
    local rc=${PIPESTATUS[0]}
    log "CODE RETOUR : $rc"
    return "$rc"
}

# die "message" : log une erreur fatale puis quitte avec le code 1.
die() {
    echo "[ERREUR] $*" >&2
    [ -f "$LOG_GLOBAL" ] && log "ERREUR FATALE : $*"
    exit 1
}

###############################################################################
# 3. DÉTECTION DE LA FAMILLE LINUX
###############################################################################
# Lit /etc/os-release (fichier standard présent sur toutes les distros modernes)
# qui contient :
#   ID=ubuntu           -> identifiant de la distro
#   ID_LIKE="debian"    -> distros "parentes" (ex: Ubuntu est "like" Debian)
# On regarde d'abord ID puis ID_LIKE pour retrouver la famille.
detecter_famille() {
    if [ ! -r /etc/os-release ]; then
        die "/etc/os-release introuvable : distribution non reconnue."
    fi

    # "source" charge les variables du fichier (ID, ID_LIKE, PRETTY_NAME...).
    # Le sous-shell ( ... ) évite de polluer nos propres variables.
    local id id_like
    id="$( . /etc/os-release; echo "${ID:-inconnu}" )"
    id_like="$( . /etc/os-release; echo "${ID_LIKE:-}" )"
    DISTRO_NOM="$( . /etc/os-release; echo "${PRETTY_NAME:-$id}" )"

    # On concatène ID et ID_LIKE pour chercher dans les deux d'un coup.
    case " ${id} ${id_like} " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" raspbian "*|*" kali "*|*" pop "*)
            FAMILLE="debian" ;;                 # gestionnaire : apt
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*|*" amzn "*)
            FAMILLE="redhat" ;;                 # gestionnaire : dnf ou yum
        *" arch "*|*" manjaro "*|*" endeavouros "*)
            FAMILLE="arch" ;;                   # gestionnaire : pacman
        *" suse "*|*" opensuse "*|*" sles "*|*" opensuse-leap "*|*" opensuse-tumbleweed "*)
            FAMILLE="suse" ;;                   # gestionnaire : zypper
        *" alpine "*)
            FAMILLE="alpine" ;;                 # gestionnaire : apk
        *)
            die "Famille non supportée (ID=${id}, ID_LIKE=${id_like})." ;;
    esac
}

###############################################################################
# 4. FONCTIONS PAR FAMILLE : rafraîchir / lister / upgrade
###############################################################################
# Chaque fonction "route" vers le bon gestionnaire selon $FAMILLE.

# --- 4.1 Rafraîchir les index (récupérer la liste des nouveautés) ------------
refresh_index() {
    case "$FAMILLE" in
        debian)
            # apt-get update : télécharge les listes de paquets des dépôts.
            run_logged "$LOG_UPDATE" apt-get update ;;
        redhat)
            # "makecache" met à jour les métadonnées des dépôts (dnf ou yum).
            run_logged "$LOG_UPDATE" "$PKG_RH" -y makecache ;;
        arch)
            # pacman -Sy : synchronise la base de données des paquets.
            run_logged "$LOG_UPDATE" pacman -Sy --noconfirm ;;
        suse)
            # zypper refresh : rafraîchit les dépôts. -n = non interactif.
            run_logged "$LOG_UPDATE" zypper --non-interactive refresh ;;
        alpine)
            # apk update : met à jour l'index des paquets.
            run_logged "$LOG_UPDATE" apk update ;;
    esac
}

# --- 4.2 Lister ce qui est à mettre à jour -----------------------------------
# Écrit la liste dans $LOG_LISTE et renseigne $NB_A_MAJ.
lister_maj() {
    : > "$LOG_LISTE"      # ":" > fichier : crée/vide le fichier proprement

    case "$FAMILLE" in
        debian)
            # apt list --upgradable : affiche les paquets pouvant être mis à jour.
            # On filtre la ligne d'en-tête "Listing..." avec grep -v.
            log "COMMANDE : apt list --upgradable"
            apt list --upgradable 2>/dev/null | grep -v '^Listing' > "$LOG_LISTE"
            ;;
        redhat)
            # check-update : code retour 100 = des maj existent, 0 = rien, 1 = erreur.
            # C'est NORMAL que ce ne soit pas 0, donc on ne le traite pas comme une erreur.
            log "COMMANDE : $PKG_RH check-update"
            "$PKG_RH" -q check-update 2>/dev/null \
                | grep -E '^[A-Za-z0-9_.+-]+\.[A-Za-z0-9_]+[[:space:]]+[0-9]' > "$LOG_LISTE"
            ;;
        arch)
            # pacman -Qu : liste les paquets installés ayant une version plus récente.
            log "COMMANDE : pacman -Qu"
            pacman -Qu 2>/dev/null > "$LOG_LISTE"
            ;;
        suse)
            # zypper list-updates : liste les maj. Les lignes utiles commencent par "v |".
            log "COMMANDE : zypper list-updates"
            zypper --non-interactive list-updates 2>/dev/null | grep -E '^v ' > "$LOG_LISTE"
            ;;
        alpine)
            # apk version -l '<' : paquets dont la version installée est inférieure au dépôt.
            log "COMMANDE : apk version -l '<'"
            apk version -l '<' 2>/dev/null | grep -v '^Installed' > "$LOG_LISTE"
            ;;
    esac

    # wc -l compte les lignes ; "tr -d ' '" retire les espaces éventuels.
    NB_A_MAJ="$(wc -l < "$LOG_LISTE" | tr -d ' ')"

    log "PAQUETS À METTRE À JOUR : ${NB_A_MAJ}"
    # On recopie la liste dans le log global pour tout avoir au même endroit.
    cat "$LOG_LISTE" >> "$LOG_GLOBAL"
}

# --- 4.3 Appliquer les mises à jour ------------------------------------------
faire_upgrade() {
    case "$FAMILLE" in
        debian)
            # DEBIAN_FRONTEND=noninteractive : empêche apt de poser des questions.
            # -y : répond "oui" automatiquement.
            # --force-confold : en cas de conflit, GARDE vos fichiers de config actuels.
            DEBIAN_FRONTEND=noninteractive run_logged "$LOG_UPGRADE" \
                apt-get -y -o Dpkg::Options::="--force-confdef" \
                           -o Dpkg::Options::="--force-confold" upgrade
            ;;
        redhat)
            run_logged "$LOG_UPGRADE" "$PKG_RH" -y upgrade ;;
        arch)
            # -Su : applique la mise à jour complète (la base a déjà été synchronisée).
            run_logged "$LOG_UPGRADE" pacman -Su --noconfirm ;;
        suse)
            # "update" met à jour sans changer de version majeure ; -n = non interactif.
            run_logged "$LOG_UPGRADE" zypper --non-interactive update ;;
        alpine)
            run_logged "$LOG_UPGRADE" apk upgrade ;;
    esac
}

# --- 4.4 Un redémarrage est-il nécessaire ? ----------------------------------
verifier_reboot() {
    case "$FAMILLE" in
        debian)
            # Debian/Ubuntu créent ce fichier quand un reboot est requis (noyau, libc...).
            [ -f /var/run/reboot-required ] && REBOOT_NEEDED="OUI" ;;
        redhat)
            # needs-restarting -r (paquet dnf-utils / yum-utils) : code 1 = reboot requis.
            if command -v needs-restarting >/dev/null 2>&1; then
                needs-restarting -r >/dev/null 2>&1 || REBOOT_NEEDED="OUI"
            else
                REBOOT_NEEDED="inconnu (needs-restarting absent)"
            fi ;;
        *)
            REBOOT_NEEDED="non vérifié pour cette famille" ;;
    esac
    log "REDÉMARRAGE NÉCESSAIRE : ${REBOOT_NEEDED}"
}

###############################################################################
# 5. RÉCAPITULATIF
###############################################################################
generer_recap() {
    local statut="SUCCÈS"
    # Si le refresh OU l'upgrade a renvoyé un code différent de 0 => ÉCHEC.
    if [ "$RC_REFRESH" -ne 0 ] || [ "$RC_UPGRADE" -ne 0 ]; then
        statut="ÉCHEC (voir les logs)"
    fi

    # Les erreurs repérées dans le log (lignes contenant error/fail/E:)
    # grep -i : insensible à la casse ; -c : compte ; "|| true" évite un code 1 si 0 trouvé.
    local nb_err
    nb_err="$(grep -Eic 'error|fail|^E:' "$LOG_GLOBAL" || true)"

    # Tout ce qui suit entre <<EOF ... EOF est écrit dans le fichier RECAP.
    cat > "$RECAP" <<EOF
===============================================================
 RÉCAPITULATIF DES MISES À JOUR
===============================================================
 Date            : ${DATE_SUJET}
 Machine         : $(hostname)
 Distribution    : ${DISTRO_NOM}
 Famille         : ${FAMILLE}
 Noyau           : $(uname -r)
---------------------------------------------------------------
 Statut global             : ${statut}
 Rafraîchissement (code)   : ${RC_REFRESH}
 Upgrade (code)            : ${RC_UPGRADE}
 Paquets à mettre à jour   : ${NB_A_MAJ}
 Lignes d'erreur dans logs : ${nb_err}
 Redémarrage nécessaire    : ${REBOOT_NEEDED}
---------------------------------------------------------------
 Dossier des logs : ${RUN_DIR}
   - global.log, 01_refresh_index.log,
     02_paquets_a_maj.log, 03_upgrade.log
---------------------------------------------------------------
 PAQUETS CONCERNÉS (avant upgrade) :
$(if [ "$NB_A_MAJ" -gt 0 ]; then cat "$LOG_LISTE"; else echo "   (aucun)"; fi)
---------------------------------------------------------------
 DERNIÈRES LIGNES DE L'UPGRADE :
$(tail -n 20 "$LOG_UPGRADE" 2>/dev/null || echo "   (pas de sortie)")
===============================================================
EOF
    log "Récapitulatif généré : ${RECAP}"
}

###############################################################################
# 6. ENVOI DU MAIL (avec le récap en pièce jointe .txt)
###############################################################################
envoyer_mail() {
    # Sujet demandé : SAUVEGARDE DU JOUR : DD/MM/YYYY - HH:mm:ss
    local sujet="SAUVEGARDE DU JOUR : ${DATE_SUJET}"
    local nom_pj="recapitulatif_maj_$(hostname)_${DATE_FICHIER}.txt"

    # Corps du mail (simple)
    local corps
    corps="Bonjour,

Les mises à jour automatiques de la machine $(hostname) sont terminées.
Distribution : ${DISTRO_NOM}
Paquets mis à jour : ${NB_A_MAJ}
Redémarrage nécessaire : ${REBOOT_NEEDED}

Vous trouverez le récapitulatif détaillé en pièce jointe.

Cordialement,
Script maj_auto.sh"

    # --- Méthode 1 (préférée) : "sendmail" + message MIME écrit à la main ------
    # Fonctionne avec postfix, exim, msmtp (qui fournit un alias sendmail), ssmtp...
    # "command -v" teste l'existence d'une commande sans l'exécuter.
    local sm=""
    for c in sendmail /usr/sbin/sendmail /usr/lib/sendmail; do
        command -v "$c" >/dev/null 2>&1 && { sm="$c"; break; }
    done

    if [ -n "$sm" ]; then
        # Séparateur unique entre le corps et la pièce jointe
        local sep="=====MAJ_AUTO_$(date +%s)====="
        {
            echo "From: ${MAIL_FROM}"
            echo "To: ${MAIL_DEST}"
            echo "Subject: ${sujet}"
            echo "MIME-Version: 1.0"
            echo "Content-Type: multipart/mixed; boundary=\"${sep}\""
            echo
            echo "--${sep}"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo "Content-Transfer-Encoding: 8bit"
            echo
            echo "$corps"
            echo
            echo "--${sep}"
            echo "Content-Type: text/plain; charset=UTF-8; name=\"${nom_pj}\""
            echo "Content-Transfer-Encoding: base64"
            echo "Content-Disposition: attachment; filename=\"${nom_pj}\""
            echo
            base64 "$RECAP"          # encode le fichier en base64 pour le mail
            echo "--${sep}--"
        } | "$sm" -t -f "$MAIL_FROM" 2>>"$LOG_GLOBAL"      # -t : lit les destinataires dans les en-têtes
        local rc=$?
        log "Mail via ${sm} : code retour ${rc}"
        return $rc
    fi

    # --- Méthode 2 : mutt (gère très bien les pièces jointes avec -a) ----------
    if command -v mutt >/dev/null 2>&1; then
        echo "$corps" | mutt -s "$sujet" -a "$RECAP" -- "$MAIL_DEST"
        local rc=$?
        log "Mail via mutt : code retour ${rc}"
        return $rc
    fi

    # --- Méthode 3 : mail / mailx (l'option de pièce jointe varie : -a ou -A) --
    if command -v mail >/dev/null 2>&1; then
        echo "$corps" | mail -s "$sujet" -a "$RECAP" "$MAIL_DEST" \
            || echo "$corps" | mail -s "$sujet" -A "$RECAP" "$MAIL_DEST"
        local rc=$?
        log "Mail via mail/mailx : code retour ${rc}"
        return $rc
    fi

    log "ATTENTION : aucun outil d'envoi de mail (sendmail/mutt/mail) installé. Mail NON envoyé."
    log "Installez par ex. : msmtp-mta (Debian) / postfix / mailx, puis configurez-le."
    return 1
}

###############################################################################
# 7. NETTOYAGE DES ANCIENS LOGS
###############################################################################
nettoyer_vieux_logs() {
    # find : cherche dans LOG_BASE les DOSSIERS (-type d) d'un seul niveau (-maxdepth 1)
    # plus vieux que N jours (-mtime +N) et les supprime (rm -rf).
    # -mindepth 1 évite de supprimer LOG_BASE lui-même.
    find "$LOG_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_JOURS" \
        -exec rm -rf {} + 2>/dev/null
    log "Nettoyage des logs de plus de ${RETENTION_JOURS} jours effectué."
}

###############################################################################
# 8. PROGRAMME PRINCIPAL
###############################################################################
main() {
    # --- 8.1 Il faut être root pour installer des paquets ---------------------
    # $EUID = identifiant de l'utilisateur courant (0 = root).
    if [ "$EUID" -ne 0 ]; then
        # On tente de se relancer automatiquement avec sudo.
        if command -v sudo >/dev/null 2>&1; then
            echo "Relance avec sudo..."
            exec sudo -E bash "$0" "$@"     # exec remplace le processus courant
        fi
        die "Ce script doit être lancé en root (sudo ./maj_auto.sh)."
    fi

    # --- 8.2 Création du répertoire de logs (par le script) ------------------
    # mkdir -p : crée aussi les dossiers parents, sans erreur s'ils existent.
    mkdir -p "$RUN_DIR" || die "Impossible de créer ${RUN_DIR}"
    chmod 750 "$LOG_BASE" "$RUN_DIR"        # lecture/écriture root + lecture groupe seulement
    : > "$LOG_GLOBAL"                       # crée le log global vide

    log "=========== DÉBUT DU SCRIPT DE MISE À JOUR ==========="
    log "Répertoire de logs : ${RUN_DIR}"

    # --- 8.3 Verrou : évite deux exécutions simultanées ----------------------
    # flock sur le descripteur 200 : si un autre exemplaire tourne, on s'arrête.
    exec 200>/var/lock/maj_auto.lock
    if ! flock -n 200; then
        die "Une autre instance du script est déjà en cours."
    fi

    # --- 8.4 Détection de la distribution ------------------------------------
    detecter_famille
    log "Distribution détectée : ${DISTRO_NOM} (famille : ${FAMILLE})"

    # Pour la famille RedHat : dnf si présent, sinon yum (CentOS 7 et plus anciens).
    PKG_RH=""
    if [ "$FAMILLE" = "redhat" ]; then
        if command -v dnf >/dev/null 2>&1; then PKG_RH="dnf"
        elif command -v yum >/dev/null 2>&1; then PKG_RH="yum"
        else die "Ni dnf ni yum trouvé."
        fi
        log "Gestionnaire RedHat utilisé : ${PKG_RH}"
    fi

    # --- 8.5 Étape 1 : rafraîchir les index ----------------------------------
    log "----- ÉTAPE 1/4 : rafraîchissement des index -----"
    refresh_index; RC_REFRESH=$?

    # --- 8.6 Étape 2 : lister ce qui est à mettre à jour ---------------------
    log "----- ÉTAPE 2/4 : liste des paquets à mettre à jour -----"
    lister_maj

    # --- 8.7 Étape 3 : upgrade (seulement s'il y a quelque chose à faire) ----
    log "----- ÉTAPE 3/4 : mise à jour des paquets -----"
    if [ "$NB_A_MAJ" -gt 0 ]; then
        faire_upgrade; RC_UPGRADE=$?
    else
        log "Rien à mettre à jour : upgrade ignoré."
        echo "Aucune mise à jour disponible." > "$LOG_UPGRADE"
    fi
    verifier_reboot

    # --- 8.8 Étape 4 : récap + mail ------------------------------------------
    log "----- ÉTAPE 4/4 : récapitulatif et envoi du mail -----"
    generer_recap
    cat "$RECAP"                            # affiche aussi le récap à l'écran
    envoyer_mail || log "Le mail n'a pas pu être envoyé (voir ci-dessus)."

    nettoyer_vieux_logs
    log "=========== FIN DU SCRIPT ==========="

    # Code de sortie : 0 si tout va bien, 1 sinon (utile pour cron/supervision).
    [ "$RC_REFRESH" -eq 0 ] && [ "$RC_UPGRADE" -eq 0 ]
}

# Lance le programme en transmettant les éventuels arguments.
main "$@"
