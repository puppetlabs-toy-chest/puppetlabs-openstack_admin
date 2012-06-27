class openstack_admin::controller::ha(
  $volume_group,
  $logical_volume,
  $primary_hostname,
  $secondary_hostname,
  $controller_hostname,
  $primary_address,
  $secondary_address,
  $public_address,
  $internal_address,
  $public_interface,
  $internal_interface,
  $ha_primary,
  $corosync_address,
  $initial_setup      = false,
  $corosync_unicast   = false,
  $multicast_address  = '226.94.1.1',
  $drbd_resource      = 'openstack',
  $drbd_device        = 'drbd0',
  $multi_host         = false,
  $stonith_enabled    = 'false'
) {

  # Additional nova configuration
  nova_config {
    'host': value => $controller_hostname;
    'routing_source_ip': value => $internal_address
  }

  $real_volume_group   = regsubst($volume_group, '-', '--', G)
  $real_logical_volume = regsubst($logical_volume, '-', '--', G)

  include 'drbd'

  drbd::resource { $drbd_resource:
    host1         => $primary_hostname,
    host2         => $secondary_hostname,
    ip1           => $primary_address,
    ip2           => $secondary_address,
    disk          => "/dev/mapper/${real_volume_group}-${real_logical_volume}",
    port          => '7789',
    device        => "/dev/${drbd_device}",
    manage        => true,
    verify_alg    => 'sha1',
    ha_primary    => $ha_primary,
    initial_setup => $initial_setup,
  }

  drbd::migration { '/var/lib/mysql':
    service    => 'mysql',
    volume     => $drbd_resource,
    ha_primary => $ha_primary,
    before     => Service['corosync'],
    require    => Package['mysql-server']
  }

  drbd::migration { '/var/lib/rabbitmq':
    service    => 'rabbitmq-server',
    volume     => $drbd_resource,
    ha_primary => $ha_primary,
    before     => Service['corosync'],
    require    => Package['rabbitmq-server']
  }

  drbd::migration { '/var/www':
    service    => 'apache2',
    volume     => $drbd_resource,
    ha_primary => $ha_primary,
    before     => Service['corosync'],
    require    => Package['apache2']
  }

  drbd::migration { '/var/lib/glance':
    service    => 'glance-api',
    volume     => $drbd_resource,
    ha_primary => $ha_primary,
    before     => Service['corosync'],
    require    => Package['glance']
  }

  # Corosync services
  if $corosync_unicast {
    $unicast_addresses = [ $primary_address, $secondary_address ]
  }

  class { 'corosync':
    enable_secauth    => false,
    bind_address      => $corosync_address,
    multicast_address => $multicast_address,
    unicast_addresses => $unicast_addresses,
  }

  corosync::service { 'pacemaker':
    version => '0',
    notify  => Service['corosync']
  }

  # The corosync primitives and relationships
  if $ha_primary {
    cs_primitive { 'clusterip_internal':
      primitive_class => 'ocf',
      provided_by     => 'heartbeat',
      primitive_type  => 'IPaddr2',
      parameters      => {
        'ip'           => $internal_address,
        'cidr_netmask' => '32',
        'nic'          => $internal_interface,
      },
      operations      => { 'monitor' => { 'interval' => '30s' } },
      metadata        => { 'is-managed' => 'true' },
    }

    if $public_address != $internal_address {
      cs_primitive { 'clusterip_public':
        primitive_class => 'ocf',
        provided_by     => 'heartbeat',
        primitive_type  => 'IPaddr2',
        parameters      => {

          'ip'           => $public_address,
          'cidr_netmask' => '32',
          'nic'          => $public_interface,
        },
        operations      => { 'monitor' => { 'interval' => '30s' } },
        metadata        => { 'is-managed' => 'true' },
      }

      cs_colocation { 'ips_together':
        primitives => ['clusterip_internal', 'clusterip_public']
      }
    }

    cs_primitive { 'drbd':
      primitive_class => 'ocf',
      provided_by     => 'linbit',
      primitive_type  => 'drbd',
      parameters      => { 'drbd_resource' => $drbd_resource },
      ms_metadata     => {
        'clone-max'       => '2',
        'clone-node-max'  => '1',
        'master-max'      => '1',
        'master-node-max' => '1',
        'notify'          => 'true'
      },
      cib             => 'openstack',
      promotable      => true,
    }

    cs_primitive { 'drbd_mount':
      primitive_class => 'ocf',
      provided_by     => 'heartbeat',
      primitive_type  => 'Filesystem',
      parameters     => {
        'device'    => "/dev/drbd/by-res/${drbd_resource}",
        'directory' => "/drbd/${drbd_resource}",
        'fstype'    => 'ext4',
      },
      cib             => 'openstack',
    }

    cs_primitive { 'mysql':
      primitive_class => 'upstart',
      primitive_type  => 'mysql',
      parameters      => { },
      cib             => 'openstack',
    }

    cs_primitive { 'rabbitmq':
      primitive_class => 'lsb',
      primitive_type  => 'rabbitmq-server',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['rabbitmq-server'],
    }

    cs_primitive { 'httpd':
      primitive_class    => 'lsb',
      primitive_type     => 'apache2',
      parameters         => { },
      cib                => 'openstack'
    }

    cs_primitive { 'keystone':
      primitive_class => 'upstart',
      primitive_type  => 'keystone',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['keystone']
    }

    cs_primitive { 'glance_api':
      primitive_class => 'upstart',
      primitive_type  => 'glance-registry',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['glance-api']
    }

    cs_primitive { 'glance_registry':
      primitive_class => 'upstart',
      primitive_type  => 'glance-api',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['glance-registry']
    }

    cs_primitive { 'nova_api':
      primitive_class => 'upstart',
      primitive_type  => 'nova-api',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-api']
    }

    cs_primitive { 'nova_cert':
      primitive_class => 'upstart',
      primitive_type  => 'nova-cert',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-cert']
    }

    cs_primitive { 'nova_consoleauth':
      primitive_class => 'upstart',
      primitive_type  => 'nova-consoleauth',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-consoleauth']
    }

    cs_primitive { 'nova_scheduler':
      primitive_class => 'upstart',
      primitive_type  => 'nova-scheduler',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-scheduler']
    }

    cs_primitive { 'nova_objectstore':
      primitive_class => 'upstart',
      primitive_type  => 'nova-objectstore',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-objectstore']
    }

    cs_primitive { 'nova_vncproxy':
      primitive_class => 'lsb',
      primitive_type  => 'novnc',
      parameters      => { },
      cib             => 'openstack',
      require         => Service['nova-vncproxy']
    }

    if ! $multi_host {
      cs_primitive { 'nova_network':
        primitive_class => 'upstart',
        primitive_type  => 'nova-network',
        parameters      => { },
        cib             => 'openstack',
        require         => Service['nova-network']
      }
    }

    cs_colocation { 'drbd_with_ip':
      primitives => ['ms_drbd:Master', 'clusterip_internal'],
      cib             => 'openstack',
    }

    cs_colocation { 'fs_with_ip':
      primitives => ['drbd_mount', 'clusterip_internal'],
      cib             => 'openstack'
    }

    cs_colocation { 'mysql_with_ip':
      primitives => ['mysql', 'clusterip_internal'],
      cib        => 'openstack'
    }

    cs_colocation { 'rabbitmq_with_ip':
      primitives => ['rabbitmq', 'clusterip_internal'],
      cib        => 'openstack'
    }

    cs_colocation { 'httpd_with_ip':
      primitives => ['httpd', 'clusterip_internal'],
      cib        => 'openstack',
    }

    cs_colocation { 'keystone_with_ip':
      primitives => ['keystone', 'clusterip_internal'],
      cib        => 'openstack',
    }

    cs_colocation { 'glance_api_with_keystone':
      primitives => ['glance_api', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'glance_registry_with_keystone':
      primitives => ['glance_registry', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'api_with_keystone':
      primitives => ['nova_api', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'cert_with_keystone':
      primitives => ['nova_cert', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'consoleauth_with_keystone':
      primitives => ['nova_consoleauth', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'schedule_with_keystone':
      primitives => ['nova_scheduler', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'objectstore_with_keystone':
      primitives => ['nova_objectstore', 'keystone'],
      cib        => 'openstack',
    }

    cs_colocation { 'vncproxy_with_keystone':
      primitives => ['nova_vncproxy', 'keystone'],
      cib        => 'openstack',
    }

    if ! $multi_host {
      cs_colocation { 'network_with_keystone':
        primitives => ['nova_network', 'keystone'],
        cib        => 'openstack',
      }
    }

    cs_order { 'fs_after_drbd':
      first  => 'ms_drbd:promote',
      second => 'drbd_mount:start',
      cib    => 'openstack'
    }

    cs_order { 'mysql_after_fs':
      first  => 'drbd_mount',
      second => 'mysql',
      cib    => 'openstack'
    }

    cs_order { 'rabbitmq_after_fs':
      first  => 'drbd_mount',
      second => 'rabbitmq',
      cib    => 'openstack'
    }

    cs_order { 'rabbitmq_after_ip':
      first  => 'clusterip_internal',
      second => 'rabbitmq',
      cib    => 'openstack',
    }

    cs_order { 'httpd_after_fs':
      first  => 'drbd_mount',
      second => 'httpd',
      cib    => 'openstack',
    }

    cs_order { 'keystone_after_mysql':
      first  => 'mysql',
      second => 'keystone',
      cib    => 'openstack',
    }

    cs_order { 'keystone_after_rabbitmq':
      first  => 'rabbitmq',
      second => 'keystone',
      cib    => 'openstack',
    }

    cs_order { 'glance_api_after_keystone':
      first  => 'keystone',
      second => 'glance_api',
      cib    => 'openstack',
    }

    cs_order { 'glance_registry_after_keystone':
      first  => 'keystone',
      second => 'glance_registry',
      cib    => 'openstack',
    }

    cs_order { 'api_after_keystone':
      first  => 'keystone',
      second => 'nova_api',
      cib    => 'openstack',
    }

    cs_order { 'cert_after_keystone':
      first  => 'keystone',
      second => 'nova_cert',
      cib    => 'openstack',
    }

    cs_order { 'consoleauth_after_keystone':
      first  => 'keystone',
      second => 'nova_consoleauth',
      cib    => 'openstack',
    }

    cs_order { 'scheduler_after_keystone':
      first  => 'keystone',
      second => 'nova_scheduler',
      cib    => 'openstack',
    }

    cs_order { 'objectstore_after_keystone':
      first  => 'keystone',
      second => 'nova_objectstore',
      cib    => 'openstack',
    }

    cs_order { 'vncproxy_after_keystone':
      first  => 'keystone',
      second => 'nova_vncproxy',
      cib    => 'openstack',
    }

    if ! $multi_host {
      cs_order { 'network_after_keystone':
        first  => 'keystone',
        second => 'nova_network',
        cib    => 'openstack'
      }
    }

    cs_property { 'no-quorum-policy':
      value => 'ignore'
    }

    cs_property { 'stonith-enabled':
      value => $stonith_enabled
    }

    # Make sure the corosync service is started before we insert the configuration
    Service['corosync'] -> Cs_property<| |>

    # corosync won't add relationships unless the primitives already exist
    Cs_primitive<| |> -> Cs_colocation<| |>
    Cs_primitive<| |> -> Cs_order<| |>
    
    # Corosync misconfiguration can cause puppet/corosync to silently fail.
    # Making sure properties are set before any other corosync stuff runs
    # helps to avoid this.
    Cs_property<| |> -> Cs_primitive<| |>
    Cs_property<| |> -> Exec['create_cib']

    # The following execs wrap things that the puppet corosync module currently can't handle

    # Make the primary host preferred for the IP (and thus for all the services)
    exec { "/usr/sbin/crm configure location ip_on_primary clusterip_internal 100: ${hostname}":
      unless      => '/usr/sbin/crm configure show | /bin/grep ip_on_primary',
      require     => Cs_primitive['clusterip_internal'],
      before      => Exec['initial-db-sync'],
    }

    # Create a corosync shadow configuration for openstack
    exec { 'create_cib':
      command => '/usr/sbin/crm cib new openstack',
      require => Service['corosync'],
    }
    Exec['create_cib'] -> Cs_primitive<| primitive_type != 'IPaddr2'  |>

    # Once all the corosync types have run, we commit the openstack
    # shadow CIB to the main corosync config
    exec { 'commit_cib':
      command     => '/usr/sbin/crm cib commit openstack',
    }
    Cs_colocation<| |> -> Exec['commit_cib']
    Cs_order<| |> -> Exec['commit_cib']
  }
    

  # This dirtiness makes sure that Corosync can manage the openstack services
  # need to let puppet try to enable them on the primary, so that the DB can be
  # loaded correctly
  if ! $ha_primary {
    Service<| title == 'httpd' |> {
      ensure => undef
    }
    Service<| title == 'mysqld' |> {
      ensure => undef
    }
    Service<| title == 'rabbitmq-server' |> {
      ensure => undef
    }
    Service<| title == 'keystone' |> {
      ensure => undef
    }
    Service<| title == 'glance-api' |> {
      ensure => undef
    }
    Service<| title == 'glance-registry' |> {
      ensure => undef
    }
    Service<| title == 'horizon' |> {
      ensure => undef
    }
    Service<| title == 'memcached' |> {
      ensure => running,
      enable => true
    }
    Service<| title == 'nova-api' |> {
      ensure => undef
    }
    Service<| title == 'nova-cert' |> {
      ensure => undef
    }
    Service<| title == 'nova-consoleauth' |> {
      ensure => undef
    }
    Service<| title == 'nova-scheduler' |> {
      ensure => undef
    }
    Service<| title == 'nova-objectstore' |> {
      ensure => undef
    }
    Service<| title == 'nova-vncproxy' |> {
      ensure => undef
    }
    Service<| title == 'nova-network' |> {
      ensure => undef
    }
  }

  # Override service users so the data can be shared across systems
  user { 'rabbitmq':
    uid    => 65500,
    gid    => 'rabbitmq',
    ensure => present,
    home   => '/var/lib/rabbitmq',
    before => Package['rabbitmq-server']
  }

  group { 'rabbitmq':
    gid    => 65500,
    ensure => present
  }

  user { 'mysql':
    uid    => 65501,
    gid    => 'mysql',
    ensure => present,
    before => Package['mysql-server']
  }

  group { 'mysql':
    gid    => 65501,
    ensure => present
  }

  # Replace the mysql apparmor configuration
  file { '/etc/apparmor.d/usr.sbin.mysqld':
    source  => "puppet:///modules/${module_name}/usr.sbin.mysqld",
    owner   => 'root',
    group   => 'root',
    require => Package['mysql-server'],
    before  => Drbd::Migration['/var/lib/mysql']
  }

  # Ensure that the rabbitmq configuration has what we need
  File<| title == 'rabbitmq-env.config' |> {
    content => template("${module_name}/rabbitmq-env.conf.erb")
  }
  # rabbitmq init script is totally insane. We need to make sure it's stopped
  # before we update the env config or it won't stop the existing service.
  exec { '/usr/sbin/service rabbitmq-server stop':
    require => Drbd::Migration['/var/lib/rabbitmq'],
    before  => File['rabbitmq-env.config']
  }

}
