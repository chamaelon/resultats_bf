# -*- mode: ruby -*-
require 'yaml'
require 'fileutils'

# Lecture du fichier .env (sans plugin) : les valeurs servent de défaut,
# une variable passée en ligne de commande (NB_APP=4 vagrant up) reste prioritaire.
FICHIER_ENV = File.join(__dir__, ".env")
if File.exist?(FICHIER_ENV)
  File.readlines(FICHIER_ENV).each do |ligne|
    ligne = ligne.strip
    next if ligne.empty? || ligne.start_with?("#") || !ligne.include?("=")
    cle, valeur = ligne.split("=", 2)
    ENV[cle.strip] ||= valeur.strip
  end
end

GROUPE = (ENV['GROUPE'] || 1).to_i # numéro de groupe, 1 à 8
NB_APP = (ENV['NB_APP'] || 2).to_i # nombre de serveurs applicatifs
abort "GROUPE doit être compris entre 1 et 8 (valeur reçue : #{GROUPE})." unless (1..8).cover?(GROUPE)
abort "NB_APP doit être compris entre 2 et 10 (valeur reçue : #{NB_APP})." unless (2..10).cover?(NB_APP)
RESEAU = "192.168.#{55 + GROUPE}"
BOITE = "bento/ubuntu-24.04"
VERSION = "202404.26.0"

# Source unique de vérité : le Vagrantfile ET la configuration du
# répartiteur sont engendrés à partir de cette table.
NOEUDS = []
# Base de données principale
NOEUDS << { nom: "bdd1", ip: "#{RESEAU}.31", mem: 768, role: "bdd",required:true }

# Base de données répliquée
NOEUDS << { nom: "bdd2", ip: "#{RESEAU}.32", mem: 768, role: "replique",required:true }

# Cache (non optionnel)
NOEUDS << { nom: "cache", ip: "#{RESEAU}.51", mem: 512, role: "cache",required:true }

# Instances applicatives
(1..NB_APP).each do |i|
  NOEUDS << { nom: "app#{i}", ip: "#{RESEAU}.#{20 + i}", mem: 512, role: "app",required:true }
end

# Répartiteurs de charge principaux
NOEUDS << { nom: "lb1", ip: "#{RESEAU}.11", mem: 512, role: "lb", required:true }

# Répartiteur de charge secondaire (optionnel)
NOEUDS << { nom: "lb2", ip: "#{RESEAU}.12", mem: 512, role: "lb2",required:false }

# Observation et monitoring (onon ptionnel)
NOEUDS << { nom: "obs", ip: "#{RESEAU}.41", mem: 768, role: "obs",required:true }


# Les scripts liront ce fichier dans /vagrant/config/noeuds.yml
FileUtils.mkdir_p("config")
File.write("config/noeuds.yml", NOEUDS.to_yaml)

Vagrant.configure("2") do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION
  config.vm.synced_folder "./app", "/vagrant/app"
  config.vm.synced_folder "./config", "/vagrant/config"
  
  NOEUDS.each do |n|
    # Les extensions (required: false) ne démarrent pas avec un simple "vagrant up" :
    # on les lance explicitement, par exemple "vagrant up lb2".
    config.vm.define n[:nom], autostart: n[:required] do |node|
      node.vm.hostname = n[:nom]
      node.vm.network "private_network", ip: n[:ip]
      node.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1" if n[:role] == "lb"

      # Installation-Configuration de Node Exporter pour la surveillance des métriques système
      node.vm.provision "shell", name: "node_exporter", inline: <<~SH
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq prometheus-node-exporter
        systemctl enable --now prometheus-node-exporter
        if command -v ufw >/dev/null; then ufw allow from #{RESEAU}.41 to any port 9100 proto tcp; fi
      SH

      # Le répartiteur est reprovisionné à chaque "vagrant up" : sa configuration
      # suit donc automatiquement NB_APP (R3). lb.sh (et lb2.sh) sont idempotents (R2).
      node.vm.provision "shell", path: "./scripts/#{n[:role]}.sh",
                        run: (n[:role].start_with?("lb") ? "always" : "once")

      # Configuration VRRP Keepalived (Extension E1)
      if n[:nom] == "lb1" || n[:nom] == "lb2"
        node.vm.provision "shell", path: "./scripts/keepalived.sh", run: "always"
      end
      
                        # Configuration de la mémoire et du nombre de CPU pour la machine virtuelle
      node.vm.provider "virtualbox" do |vb|
        vb.memory = n[:mem]
        vb.cpus = 1
      end
    end
  end
end