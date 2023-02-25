Do these steps to apply patches manually;

There is two files that we need to modify;

## Qemu.pm
At : /usr/share/perl5/PVE/API2/Qemu.pm

We need to change user password to cleartext because it is hashed as default and Cloudbase-Init can not use it as it is.
We can get the os type from the options of the VM so we will use to prevent Proxmox from hashing it if it is a Windows VM.

The code to edit in my $update_vm_api fonction is belove;
 

```
    my $conf = PVE::QemuConfig->load_config($vmid);
    my $ostype = $conf->{ostype};

    if (defined(my $cipassword = $param->{cipassword})) {
        # Same logic as in cloud-init (but with the regex fixed...)
        if (!(PVE::QemuServer::windows_version($ostype))) { # new if block for support windowsand insert old code inside it
            $param->{cipassword} = PVE::Tools::encrypt_pw($cipassword)
                if $cipassword !~ /^\$(?:[156]|2[ay])(\$.+){2}/;
        }    
    } 
```

## Cloudinit.pm
At : /usr/share/perl5/PVE/QemuServer/Cloudinit.pm

We have a few changes to make to generate a meta_data.json that is compatible with Cloudbase-Init.

* sub configdrive2_network

We add a few lines to add DNS config

```
sub configdrive2_network {
    my ($conf) = @_;

    my $content = "auto lo\n";
    $content .= "iface lo inet loopback\n\n";

    my ($searchdomains, $nameservers) = get_dns_conf($conf);
    
    ## support windows
    my $ostype = $conf->{"ostype"};
    my $default_dns = '';                                                                                                                                                                                          
    my $default_search = '';
    ##

    if ($nameservers && @$nameservers) {
        $nameservers = join(' ', @$nameservers);
        $content .= "        dns_nameservers $nameservers\n";
        $default_dns = $nameservers; # Support windows
    }
    if ($searchdomains && @$searchdomains) {
        $searchdomains = join(' ', @$searchdomains);
        $content .= "        dns_search $searchdomains\n";
        $default_search = $searchdomains; # Support windows
    }

    my @ifaces = grep { /^net(\d+)$/ } keys %$conf;
    foreach my $iface (sort @ifaces) {
        (my $id = $iface) =~ s/^net//;
        next if !$conf->{"ipconfig$id"};
        my $net = PVE::QemuServer::parse_ipconfig($conf->{"ipconfig$id"});
        $id = "eth$id";

        $content .="auto $id\n";
        if ($net->{ip}) {
            if ($net->{ip} eq 'dhcp') {
                $content .= "iface $id inet dhcp\n";
            } else {
                my ($addr, $mask) = split_ip4($net->{ip});
                $content .= "iface $id inet static\n";
                $content .= "        address $addr\n";
                $content .= "        netmask $mask\n";
                $content .= "        gateway $net->{gw}\n" if $net->{gw};
                ## Support Windows
                if(PVE::QemuServer::windows_version($ostype) && ($id eq "eth0")) {
                    $content .= "        dns-nameservers $default_dns\n";
                    $content .= "        dns-search $default_search\n";
                }
                ##
            }
        }
        if ($net->{ip6}) {
            if ($net->{ip6} =~ /^(auto|dhcp)$/) {
                $content .= "iface $id inet6 $1\n";
            } else {
                my ($addr, $mask) = split('/', $net->{ip6});
                $content .= "iface $id inet6 static\n";
                $content .= "        address $addr\n";
                $content .= "        netmask $mask\n";
                $content .= "        gateway $net->{gw6}\n" if $net->{gw6};
            }
        }
    }

    return $content;
}

```

* New fonction before sub configdrive2_gen_metadata

Cloudbase-Init doesnt turn static network adapters back to DHCP configuration. This fonction will provide us the mac adresses of adapters to turn on dhcp from our config file and we will use it later with our script to enable dhcp on those network adapters.

```
sub get_mac_addresses {
    my ($conf) = @_;
    
    my $dhcpstring = undef;
    my @dhcpmacs = ();
    my @ifaces = grep { /^net(\d+)$/ } keys %$conf;
    
    foreach my $iface (sort @ifaces) {
        (my $id = $iface) =~ s/^net//;
        my $net = PVE::QemuServer::parse_net($conf->{$iface});
        next if !$conf->{"ipconfig$id"};
        my $ipconfig = PVE::QemuServer::parse_ipconfig($conf->{"ipconfig$id"});
        
        my $mac = lc $net->{macaddr};

        if (($ipconfig->{ip}) and ($ipconfig->{ip} eq 'dhcp')){
            push @dhcpmacs, $mac;
        }
    }

    if (@dhcpmacs){
        $dhcpstring = ",\n     \"dhcp\":[";
        foreach my $mac (@dhcpmacs){
            if ($mac != @dhcpmacs[-1]){
                $dhcpstring .= "\"$mac\",";
            }
            else{
                $dhcpstring .= "\"$mac\"]";
            }
        }
    }
    return ($dhcpstring);
}

```

* configdrive2_gen_metadata
We will generate our meta data variables from this fonction and call the give to another fonction which will format them.
We get DHCP macs from our previous fonction, UUID, Hostname, Username, Password and we generate a json list from ssh keys.

```
sub configdrive2_gen_metadata {
    my ($conf, $vmid, $user, $network) = @_;

    # Get mac addresses of dhcp nics from conf file  
    my $dhcpmacs = undef;
    $dhcpmacs = get_mac_addresses($conf);

    # Get UUID
    my $uuid_str = Digest::SHA::sha1_hex($user.$network);

    # Get hostname
    my ($hostname, $fqdn) = get_hostname_fqdn($conf, $vmid);

    # Get username, default to Administrator if none
    my $username = undef;
    if (defined($conf->{ciuser})){
        my $name = $conf->{ciuser};
        $username = ",\n        \"admin_username\": \"$name\""
    }

    # Get user password
    my $password = $conf->{cipassword};

    # Get ssh keys and make a list out of it in json format
    my $keystring = undef;
    my $pubkeys = $conf->{sshkeys};
    $pubkeys = URI::Escape::uri_unescape($pubkeys);
    my @pubkeysarray = split "\n", $pubkeys;
    if (@pubkeysarray) {
        my $arraylength = @pubkeysarray;
        my $incrementer = 1;
        $keystring =",\n     \"public_keys\": {\n";
        for my $key (@pubkeysarray){
            $keystring .= "        \"SSH${incrementer}\" : \"${key}\"";
            if ($arraylength != $incrementer){
                $keystring .= ",\n";
            }else{
                $keystring .= "\n     }";
            }
            $incrementer++;
        }
    }

    return configdrive2_metadata($password, $uuid_str, $hostname, $username, $keystring, $network, $dhcpmacs);
}
```

* configdrive2_metadata

This will format a json file, with our previously generated values, in a very stringy way since this is how proxmox originally generates this data.

```
sub configdrive2_metadata {
    my ($password, $uuid, $hostname, $username, $pubkeys, $network, $dhcpmacs) = @_;
    return <<"EOF";
{
     "meta":{
        "admin_pass": "$password"$username
     },
     "uuid":"$uuid",
     "hostname":"$hostname",
     "network_config":{"content_path":"/content/0000"}$pubkeys$dhcpmacs
}
EOF
}
```



