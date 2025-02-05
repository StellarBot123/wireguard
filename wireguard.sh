#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Ce script installe et configure WireGuard sur Ubuntu.
# Il crée également une paire de clés pour un client unique.
#
# Usage :
#   sudo bash install_wireguard.sh
#
# ------------------------------------------------------------------------------

# =============== Variables à personnaliser ====================================

INTERFACE="wg0"
SERVER_PORT="51820"
SERVER_NETWORK="10.8.0.0/24"
SERVER_IP="10.8.0.1"
CLIENT_IP="10.8.0.2"

# ==============================================================================
# Vérification si l'utilisateur est root
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Veuillez exécuter ce script en tant que root (ou via sudo)."
  exit 1
fi

# Mise à jour des dépôts et installation de WireGuard
echo "[*] Installation de WireGuard..."
apt-get update -y
apt-get install -y wireguard qrencode

# Création du dossier /etc/wireguard s'il n'existe pas
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# ------------------------------------------------------------------------------
# Génération des clés pour le serveur
echo "[*] Génération des clés pour le serveur..."
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
SERVER_PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)

# Génération des clés pour un client (client1)
echo "[*] Génération des clés pour le client (client1)..."
wg genkey | tee /etc/wireguard/client1_private.key | wg pubkey > /etc/wireguard/client1_public.key
CLIENT_PRIVATE_KEY=$(cat /etc/wireguard/client1_private.key)
CLIENT_PUBLIC_KEY=$(cat /etc/wireguard/client1_public.key)

chmod 600 /etc/wireguard/{server_private.key,client1_private.key}

# ------------------------------------------------------------------------------
# Configuration du serveur WireGuard : /etc/wireguard/wg0.conf
# On active le serveur sur l'IP SERVER_IP (dans le sous-réseau SERVER_NETWORK),
# On écoute sur le port SERVER_PORT
# On autorise la redirection de paquets (pour routage)
#
# On ajoute un Peer pour le client1 avec sa clé publique
# et on lui attribue l'IP CLIENT_IP dans le même sous-réseau.
#
echo "[*] Création du fichier de configuration serveur /etc/wireguard/${INTERFACE}.conf"

cat > /etc/wireguard/${INTERFACE}.conf << EOF
[Interface]
Address = ${SERVER_IP}/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
SaveConfig = false

# Client1
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

chmod 600 /etc/wireguard/${INTERFACE}.conf

# ------------------------------------------------------------------------------
# Activation de la redirection IPv4 (et IPv6 si besoin)
echo "[*] Activation du routage IPv4..."
sed -i '/^#net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# Si vous voulez aussi IPv6 :
# sed -i '/^#net.ipv6.conf.all.forwarding=1/s/^#//g' /etc/sysctl.conf
# sysctl -w net.ipv6.conf.all.forwarding=1

# ------------------------------------------------------------------------------
# Configuration iptables : on accepte l'entrée sur le port UDP SERVER_PORT
# et on fait un MASQUERADE pour le sous-réseau WireGuard
echo "[*] Configuration iptables..."
# On accepte l'interface wg0
iptables -A INPUT -i ${INTERFACE} -j ACCEPT
iptables -A FORWARD -i ${INTERFACE} -j ACCEPT

# On autorise l'UDP sur le port spécifié pour WireGuard
iptables -A INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT

# NAT (masquerade) pour le trafic sortant depuis le sous-réseau WireGuard
iptables -t nat -A POSTROUTING -s ${SERVER_NETWORK} -o "$(ip route get 8.8.8.8 | awk '/dev/ {print $5}')" -j MASQUERADE

# Sauvegarde des règles iptables
apt-get install -y iptables-persistent
netfilter-persistent save

# ------------------------------------------------------------------------------
# Démarrage du service WireGuard
echo "[*] Démarrage de l'interface WireGuard ${INTERFACE}..."
systemctl enable wg-quick@${INTERFACE}
systemctl start wg-quick@${INTERFACE}
sleep 2

# Vérification de l'état
echo "[*] État WireGuard :"
wg show

# ------------------------------------------------------------------------------
# Fichier de configuration du client (client1)
# client1.conf
# L'utilisateur importera ce fichier dans son application WireGuard
CLIENT_CONFIG_PATH="/etc/wireguard/client1.conf"
echo "[*] Création du fichier client1.conf à ${CLIENT_CONFIG_PATH}"

cat > ${CLIENT_CONFIG_PATH} << EOF
[Interface]
Address = ${CLIENT_IP}/24
PrivateKey = ${CLIENT_PRIVATE_KEY}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = $(curl -s ifconfig.me):${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 ${CLIENT_CONFIG_PATH}

# ------------------------------------------------------------------------------
# Génération d'un QR code pour le client (optionnel)
echo "[*] QR Code pour client1 (WireGuard) :"
qrencode -t ansiutf8 < ${CLIENT_CONFIG_PATH}

# ------------------------------------------------------------------------------
echo
echo "========================================================================"
echo "[*] Installation et configuration terminées !"
echo "Serveur WireGuard : ${INTERFACE} (port UDP ${SERVER_PORT})"
echo "Clé publique serveur : ${SERVER_PUBLIC_KEY}"
echo "Clé publique client1 : ${CLIENT_PUBLIC_KEY}"
echo
echo "Le fichier client est disponible ici : ${CLIENT_CONFIG_PATH}"
echo "Vous pouvez l'importer dans un client WireGuard."
echo "========================================================================"
