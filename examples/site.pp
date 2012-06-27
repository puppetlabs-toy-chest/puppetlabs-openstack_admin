#
# This document serves as an example of how to deploy
# basic single and multi-node openstack environments
# with high-availability on the controller
#

#
# Things to watch out for, compared to a standard openstack::controller setup:
#  * $controller_hostname: The hostname of the controller as seen by other
#    hosts. Shared by both the primary and secondary controller nodes.
#  * $controller_hostname_{primary,secondary}: The actual hostnames of the
#    primary/secondary controller nodes
#  * $controller_address_{primary,secondary}: The actual IP addresses of the
#    primary/secondary controller nodes

# deploy a script that can be used to test nova
class { 'openstack::test_file': }

####### shared variables ##################


# this section is used to specify global variables that will
# be used in the deployment of multi and single node openstack
# environments

# Only multi-host is currently supported for HA mode.
$multi_host              = true
# By default, corosync uses multicasting. It is possible to disable
# this if your environment require it
$corosync_unicast        = true
# assumes that eth0 is the public interface
$public_interface        = 'eth0'
# assumes that eth1 is the interface that will be used for the vm network
# this configuration assumes this interface is active but does not have an
# ip address allocated to it.
$private_interface       = 'eth1'
# credentials
$admin_email             = 'root@localhost'
$admin_password          = 'keystone_admin'
$keystone_db_password    = 'keystone_db_pass'
$keystone_admin_token    = 'keystone_admin_token'
$nova_db_password        = 'nova_pass'
$nova_user_password      = 'nova_pass'
$glance_db_password      = 'glance_pass'
$glance_user_password    = 'glance_pass'
$rabbit_password         = 'openstack_rabbit_password'
$rabbit_user             = 'openstack_rabbit_user'
$fixed_network_range     = '10.0.0.0/24'
# switch this to true to have all service log at verbose
$verbose                 = 'false'
# by default it does not enable atomatically adding floating IPs
$auto_assign_floating_ip = 'false'
# Switch this to false after your first run to prevent unsafe operations
# from potentially running again
$initial_setup           = true


#### end shared variables #################

# multi-node specific parameters

# The address services will attempt to connect to the controller with
$controller_node_address       = '192.168.101.100'
$controller_node_public        = $controller_node_address
$controller_node_internal      = $controller_node_address

# The hostname other nova nodes see the controller as
$controller_hostname           = 'controller'

# The actual address of the primary/active controller
$controller_node_primary       = '192.168.101.11'
$controller_hostname_primary   = 'active'

# The actual address of the secondary/passive controller
$controller_node_secondary     = '192.168.101.12'
$controller_hostname_secondary = 'passive'

# The bind address for corosync. Should match the subnet the controller
# nodes use for the actual IP addresses
$controller_node_network       = '192.168.101.0'

$sql_connection = "mysql://nova:${nova_db_password}@${controller_node_address}/nova"

# /etc/hosts entries for the controller nodes
host { $controller_hostname_primary:
  ip => $controller_node_primary
}
host { $controller_hostname_secondary:
  ip => $controller_node_secondary
}
host { $controller_hostname:
  ip => $controller_node_internal
}


####
# Active and passive nodes are mostly configured identically.
# There are only two places where the configuration is different:
# whether openstack::controller is flagged as enabled, and whether
# $ha_primary is set to true on openstack_admin::controller::ha
####

node active {

  # In your actual configuration you should configure the volume_group
  # to use whatever physical devices you intend to replicate with drbd.
  # This loopback volume is for an EXAMPLE ONLY.
  exec { 'dd':
    command =>'/bin/dd if=/dev/zero of=/var/volume bs=1024 count=106496',
    creates => '/var/volume',
    notify  => Exec['losetup']
  }

  exec { 'losetup':
    command => '/sbin/losetup /dev/loop0 /var/volume',
    refreshonly => true,
    before => Volume_group['nova-volumes']
  }

  volume_group { 'nova-volumes':
    physical_volumes => '/dev/loop0',
  }

  # This volume needs to be large enough to contain:
  # * rabbitmq's data directory
  # * mysql data directory
  # * glance images
  #
  # It should be fairly large in a real-world deployment.
  logical_volume { 'drbd-openstack':
    ensure       => present,
    volume_group => 'nova-volumes',
    size         => '100M',
    require      => Volume_group['nova-volumes']
  }

  class { 'openstack::controller':
    public_address          => $controller_node_public,
    public_interface        => $public_interface,
    private_interface       => $private_interface,
    internal_address        => $controller_node_internal,
    floating_range          => '192.168.101.64/28',
    fixed_range             => $fixed_network_range,
    # by default it does not enable multi-host mode
    multi_host              => $multi_host,
    # by default is assumes flat dhcp networking mode
    network_manager         => 'nova.network.manager.FlatDHCPManager',
    verbose                 => $verbose,
    auto_assign_floating_ip => $auto_assign_floating_ip,
    mysql_root_password     => $mysql_root_password,
    admin_email             => $admin_email,
    admin_password          => $admin_password,
    keystone_db_password    => $keystone_db_password,
    keystone_admin_token    => $keystone_admin_token,
    glance_db_password      => $glance_db_password,
    glance_user_password    => $glance_user_password,
    nova_db_password        => $nova_db_password,
    nova_user_password      => $nova_user_password,
    rabbit_password         => $rabbit_password,
    rabbit_user             => $rabbit_user,
    export_resources        => false,
    enabled                 => true, # Different between active and passive
  }

  class { 'openstack::auth_file':
    admin_password       => $admin_password,
    keystone_admin_token => $keystone_admin_token,
    controller_node      => $controller_node_address,
  }

  class { 'openstack_admin::controller::ha':
    public_address      => $controller_node_public,
    public_interface    => $public_interface,
    internal_address    => $controller_node_internal,
    internal_interface  => $public_interface,
    primary_hostname    => $controller_hostname_primary,
    secondary_hostname  => $controller_hostname_secondary,
    controller_hostname => $controller_hostname,
    primary_address     => $controller_node_primary,
    secondary_address   => $controller_node_secondary,
    ha_primary          => true, # Different between active and passive
    volume_group        => 'nova-volumes',
    logical_volume      => 'drbd-openstack',
    corosync_address    => $controller_node_network,
    multi_host          => $multi_host,
    corosync_unicast    => $corosync_unicast,
    initial_setup       => $initial_setup,
  }
}

node passive {

  exec { 'dd':
    command =>'/bin/dd if=/dev/zero of=/var/volume bs=1024 count=106496',
    creates => '/var/volume',
    notify  => Exec['losetup']
  }

  exec { 'losetup':
    command => '/sbin/losetup /dev/loop0 /var/volume',
    refreshonly => true,
    before => Volume_group['nova-volumes']
  }

  volume_group { 'nova-volumes':
    physical_volumes => '/dev/loop0',
  }

  logical_volume { 'drbd-openstack':
    ensure       => present,
    volume_group => 'nova-volumes',
    size         => '100M',
    require      => Volume_group['nova-volumes']
  }

  class { 'openstack::controller':
    public_address          => $controller_node_public,
    public_interface        => $public_interface,
    private_interface       => $private_interface,
    internal_address        => $controller_node_internal,
    floating_range          => '192.168.101.64/28',
    fixed_range             => $fixed_network_range,
    multi_host              => $multi_host,
    # by default is assumes flat dhcp networking mode
    network_manager         => 'nova.network.manager.FlatDHCPManager',
    verbose                 => $verbose,
    auto_assign_floating_ip => $auto_assign_floating_ip,
    mysql_root_password     => $mysql_root_password,
    admin_email             => $admin_email,
    admin_password          => $admin_password,
    keystone_db_password    => $keystone_db_password,
    keystone_admin_token    => $keystone_admin_token,
    glance_db_password      => $glance_db_password,
    glance_user_password    => $glance_user_password,
    nova_db_password        => $nova_db_password,
    nova_user_password      => $nova_user_password,
    rabbit_password         => $rabbit_password,
    rabbit_user             => $rabbit_user,
    export_resources        => false,
    enabled                 => false, # Different between active and passive
  }

  class { 'openstack::auth_file':
    admin_password       => $admin_password,
    keystone_admin_token => $keystone_admin_token,
    controller_node      => $controller_node_address,
  }

  class { 'openstack_admin::controller::ha':
    public_address      => $controller_node_public,
    public_interface    => $public_interface,
    internal_address    => $controller_node_internal,
    internal_interface  => $public_interface,
    primary_hostname    => $controller_hostname_primary,
    secondary_hostname  => $controller_hostname_secondary,
    controller_hostname => $controller_hostname,
    primary_address     => $controller_node_primary,
    secondary_address   => $controller_node_secondary,
    ha_primary          => false, # Different between active and passive
    volume_group        => 'nova-volumes',
    logical_volume      => 'drbd-openstack',
    corosync_address    => $controller_node_network,
    multi_host          => $multi_host,
    corosync_unicast    => $corosync_unicast,
    initial_setup       => $initial_setup,
  }
}

# The compute node is configured identically to a non-ha setup.
# The $controller_node_public and $controller_node_internal
# addresses should match those managed by the HA class.

node compute {

  class { 'openstack::compute':
    public_interface   => $public_interface,
    private_interface  => $private_interface,
    internal_address   => $ipaddress_eth0,
    libvirt_type       => 'kvm',
    fixed_range        => $fixed_network_range,
    network_manager    => 'nova.network.manager.FlatDHCPManager',
    multi_host         => $multi_host,
    sql_connection     => $sql_connection,
    nova_user_password => $nova_user_password,
    rabbit_host        => $controller_node_internal,
    rabbit_password    => $rabbit_password,
    rabbit_user        => $rabbit_user,
    glance_api_servers => "${controller_node_internal}:9292",
    vncproxy_host      => $controller_node_public,
    vnc_enabled        => 'true',
    verbose            => $verbose,
    manage_volumes     => true,
    nova_volume        => 'nova-volumes'
  }

}
