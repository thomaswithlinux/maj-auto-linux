# maj-auto-linux

> Script Bash de **mise à jour automatique** pour serveurs Linux : il détecte la distribution, met à jour les paquets, garde des logs détaillés et envoie un récapitulatif par e-mail.

**Description courte (pour le champ « About » de GitHub) :**
`Script Bash multi-distributions de mise à jour automatique des paquets, avec logs détaillés et récapitulatif envoyé par mail.`

---

## Sommaire

- [À quoi ça sert ?](#à-quoi-ça-sert-)
- [Fonctionnalités](#fonctionnalités)
- [Distributions supportées](#distributions-supportées)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration](#configuration)
- [Utilisation](#utilisation)
- [Automatiser avec cron](#automatiser-avec-cron)
- [Logs générés](#logs-générés)
- [Le mail de récapitulatif](#le-mail-de-récapitulatif)
- [Code de sortie](#code-de-sortie)
- [Sécurité et bonnes pratiques](#sécurité-et-bonnes-pratiques)
- [Licence](#licence)

---

## À quoi ça sert ?

> 💡 **Analogie :** imagine un **concierge d'immeuble** qui, chaque nuit, vérifie si des réparations sont à faire, les effectue, note tout dans un cahier, puis te dépose un résumé dans ta boîte aux lettres. Ce script est ce concierge pour ton serveur.

Mettre à jour un serveur régulièrement est essentiel (correctifs de sécurité, corrections de bugs). Ce script automatise toute la routine, quelle que soit la distribution Linux utilisée.

## Fonctionnalités

1. **Détection automatique** de la famille Linux (via `/etc/os-release`).
2. **Rafraîchissement** des index de paquets (équivalent de `apt update`).
3. **Liste** des paquets à mettre à jour avant de les installer.
4. **Mise à jour** non interactive des paquets (`upgrade`).
5. **Logs complets** dans un dossier horodaté créé par le script.
6. **Récapitulatif** `.txt` (statut, nombre de paquets, redémarrage nécessaire, extrait de l'upgrade).
7. **Envoi par mail** du récapitulatif en pièce jointe.
8. **Verrou anti-doublon** (`flock`) : impossible de lancer deux instances en même temps.
9. **Nettoyage automatique** des logs de plus de 30 jours.
10. **Auto-relance avec `sudo`** si le script n'est pas lancé en root.

## Distributions supportées

| Famille  | Distributions (exemples)                              | Gestionnaire |
|----------|-------------------------------------------------------|--------------|
| Debian   | Debian, Ubuntu, Linux Mint, Raspbian, Kali, Pop!_OS   | `apt`        |
| Red Hat  | RHEL, Fedora, CentOS, Rocky, AlmaLinux, Oracle, Amazon| `dnf` / `yum`|
| Arch     | Arch, Manjaro, EndeavourOS                            | `pacman`     |
| SUSE     | openSUSE (Leap/Tumbleweed), SLES                      | `zypper`     |
| Alpine   | Alpine Linux                                          | `apk`        |

## Prérequis

- Un système Linux avec **Bash** et les droits **root** (ou `sudo`).
- Pour l'envoi de mail : un agent de messagerie configuré, fournissant au choix :
  - `sendmail` (postfix, exim, msmtp, ssmtp…) — méthode préférée, avec pièce jointe MIME ;
  - `mutt` ;
  - `mail` / `mailx`.
- Le script essaie ces méthodes dans cet ordre. Si aucune n'est disponible, la mise à jour a quand même lieu, seul le mail n'est pas envoyé.

> 💡 **Analogie :** le script sait *rédiger* la lettre, mais il lui faut un *facteur* (le MTA) pour la livrer. Sans facteur configuré, la lettre reste sur le bureau.

## Installation

```bash
git clone https://github.com/thomaswithlinux/maj-auto-linux.git
cd maj-auto-linux
chmod +x maj_auto.sh
```

## Configuration

Les paramètres se trouvent au début de `maj_auto.sh`, section **« 1. CONFIGURATION »** :

| Variable          | Rôle                                              | Valeur par défaut              |
|-------------------|---------------------------------------------------|--------------------------------|
| `MAIL_DEST`       | Adresse qui reçoit le récapitulatif               | `thomasletard3@gmail.com`      |
| `MAIL_FROM`       | Expéditeur affiché                                | `maj-auto@<nom-de-la-machine>` |
| `LOG_BASE`        | Dossier racine des logs                           | `/var/log/maj_auto`            |
| `RETENTION_JOURS` | Âge (en jours) au-delà duquel les logs sont supprimés | `30`                       |

⚠️ Pense à remplacer `MAIL_DEST` par **ta propre adresse** si tu n'es pas le propriétaire initial du script.

## Utilisation

```bash
sudo ./maj_auto.sh
```

Le script affiche sa progression à l'écran en 4 étapes :

1. Rafraîchissement des index
2. Liste des paquets à mettre à jour
3. Mise à jour des paquets (ignorée s'il n'y a rien à faire)
4. Récapitulatif et envoi du mail

## Automatiser avec cron

Pour l'exécuter chaque nuit à 3h00, édite la crontab de root :

```bash
sudo crontab -e
```

puis ajoute :

```cron
0 3 * * * /chemin/vers/maj_auto.sh >/dev/null 2>&1
```

> 💡 **Analogie :** `cron` est le **réveil programmable** de Linux : il lance le script à l'heure voulue, sans que tu aies à y penser.

## Logs générés

Chaque exécution crée son propre dossier horodaté :

```
/var/log/maj_auto/
└── 20261005_143012/
    ├── global.log              # journal complet
    ├── 01_refresh_index.log    # sortie du rafraîchissement des index
    ├── 02_paquets_a_maj.log    # liste des paquets concernés
    ├── 03_upgrade.log          # sortie de l'upgrade
    └── RECAPITULATIF.txt       # résumé envoyé par mail
```

Le dossier est protégé (`chmod 750`) : seuls root et son groupe peuvent le lire.

## Le mail de récapitulatif

- **Sujet :** `SAUVEGARDE DU JOUR : JJ/MM/AAAA - HH:mm:ss`
- **Corps :** machine, distribution, nombre de paquets, redémarrage nécessaire.
- **Pièce jointe :** `recapitulatif_maj_<machine>_<date>.txt`.

## Code de sortie

| Code | Signification                                             |
|------|-----------------------------------------------------------|
| `0`  | Rafraîchissement et upgrade réussis                       |
| `1`  | Une étape a échoué, ou erreur fatale (utile pour cron / supervision) |

## Sécurité et bonnes pratiques

- Les fichiers de configuration existants sont **conservés** lors des mises à jour Debian/Ubuntu (`--force-confold`).
- L'upgrade n'effectue pas de changement de version majeure de la distribution.
- Le redémarrage n'est **jamais** fait automatiquement : le mail t'indique simplement s'il est nécessaire (vérifié sur Debian/Ubuntu et Red Hat).
- Teste d'abord le script sur une machine non critique avant de l'automatiser en production.

## Licence

Distribué sous licence **Apache 2.0** — voir le fichier [LICENSE](LICENSE).
