#!/usr/bin/env bash

opam init -y
eval `opam config env`
echo '. /home/vagrant/.opam/opam-init/init.sh > /dev/null 2> /dev/null || true' > ~/.bashrc
opam repository add frenetic-opam https://github.com/frenetic-lang/opam-bleeding.git
opam update
opam install -y frenetic openflow topology packet

# There's a bug in bison 2.7 that requires us to use 2.5 to build the of13 softswitch. This grabs an old version of bison, installs it, and then prevents mininet from trying to override our fixed version
wget http://launchpadlibrarian.net/122078648/libbison-dev_2.5.dfsg-3ubuntu1_amd64.deb
wget wget http://launchpadlibrarian.net/122078647/bison_2.5.dfsg-3ubuntu1_amd64.deb
sudo dpkg -i libbison-dev_2.5.dfsg-3ubuntu1_amd64.deb
sudo dpkg -i bison_2.5.dfsg-3ubuntu1_amd64.deb
sudo apt-mark hold libbison-dev bison
sed -i 's/\<bison\>//g' mininet/util/install.sh 

git clone git://github.com/mininet/mininet
git checkout -b 2.1.0 2.1.0
cd mininet
# Install 1.3 softswitch, openvswitch, kernel module, wireshark disector
. util/install.sh -3f -mwv
