module Moonshine::Manifest::Rails::Passenger
  # Install the passenger gem
  def passenger_gem
    configure(:passenger => {})
    package "passenger",
      :ensure => (configuration[:passenger][:version] || :latest),
      :provider => :gem,
      :require => [ package('libcurl4-gnutls-dev') ]
    package 'libcurl4-gnutls-dev', :ensure => :installed
  end

  def passenger_nginx
    configure(:nginx => {})

    package 'libcurl4-openssl-dev', :ensure => :installed

    exec 'build_passenger_nginx',
      :command => 'sudo -i passenger-install-nginx-module --auto --auto-download --prefix=/opt/nginx',
      # use echo to negate Puppet's #checkexe which runs on :unless for some wierd reason
      :unless => "echo && /opt/nginx/sbin/nginx -V 2>&1 | grep #{configuration[:passenger][:path]}",
      :require => [package('passenger')]

    file '/opt/nginx/conf/nginx.conf',
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'nginx.conf.erb')),
      :require => [exec('build_passenger_nginx')],
      :notify => [exec('nginx_reload')],
      :alias => 'nginx_conf'

    file '/etc/init.d/nginx',
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'nginx.init.erb')),
      :mode => 755,
      :require => [exec('build_passenger_nginx')],
      :notify => [exec('nginx_restart')],
      :alias => 'nginx_init'

    group 'www',
      :ensure => :present

    user 'www',
      :ensure => :present,
      :home => '/opt/nginx',
      :shell => '/bin/false',
      :gid => 'www'

    exec 'nginx_reload',
      :command => '/etc/init.d/nginx reload',
      :require => [exec('build_passenger_nginx'), file('nginx_init')],
      :refreshonly => true

    exec 'nginx_restart',
      :command => '/etc/init.d/nginx restart',
      :require => [exec('build_passenger_nginx'), file('nginx_init')],
      :refreshonly => true

    service 'nginx',
      :require => [exec('build_passenger_nginx'), file('nginx_init')],
      :enable => true
  end

  def passenger_nginx_site
    file '/opt/nginx/conf/vhosts',
      :ensure => :directory,
      :require => [exec('build_passenger_nginx')],
      :alias => 'passenger_nginx_vhost_directory'

    file '/opt/nginx/conf/vhosts/on',
      :ensure => :directory,
      :require => [exec('build_passenger_nginx')],
      :alias => 'passenger_nginx_vhost_on'

    file "/opt/nginx/conf/vhosts/#{configuration[:application]}.common",
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger_nginx.vhost.common.erb')),
      :require => [exec('build_passenger_nginx')],
      :notify => [exec('nginx_reload')],
      :alias => 'passenger_nginx_vhost_common'

    file "/opt/nginx/conf/vhosts/#{configuration[:application]}.conf",
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger_nginx.vhost.conf.erb')),
      :require => [exec('build_passenger_nginx'), file('passenger_nginx_vhost_directory')],
      :notify => [exec('nginx_reload')],
      :alias => 'passenger_nginx_vhost_conf'

    file "/opt/nginx/conf/vhosts/on/#{configuration[:application]}.conf",
      :ensure => "/opt/nginx/conf/vhosts/#{configuration[:application]}.conf",
      :require => [exec('build_passenger_nginx'), file('passenger_nginx_vhost_conf'), file('passenger_nginx_vhost_on')],
      :notify => [exec('nginx_reload')],
      :alias => 'passenger_nginx_vhost'
  end

  # Build, install, and enable the passenger apache module. Please see the
  # <tt>passenger_apache.conf.erb</tt> template for passenger configuration
  # options.
  def passenger_apache_module
    # Install Apache2 developer library
    package "apache2-threaded-dev", :ensure => :installed

    file "/usr/local/src", :ensure => :directory

    exec "symlink_apache_passenger",
      :command => 'ln -nfs `passenger-config --root` /usr/local/src/passenger',
      :unless => 'ls -al /usr/local/src/passenger | grep `passenger-config --root`',
      :require => [
        package("passenger"),
        file("/usr/local/src")
      ]

    # Build Passenger from source
    exec "build_apache_passenger",
      :cwd => configuration[:passenger][:path],
      :command => 'sudo /usr/bin/ruby -S rake clean apache2',
      :unless => "ls `passenger-config --root`/ext/apache2/mod_passenger.so",
      :require => [
        package("passenger"),
        package("apache2-mpm-worker"),
        package("apache2-threaded-dev"),
        exec('symlink_apache_passenger')
      ]

    load_template = "LoadModule passenger_module #{configuration[:passenger][:path]}/ext/apache2/mod_passenger.so"

    file '/etc/apache2/mods-available/passenger.load',
      :ensure => :present,
      :content => load_template,
      :require => [exec("build_apache_passenger")],
      :notify => service("apache2"),
      :alias => "passenger_apache_load"

    file '/etc/apache2/mods-available/passenger.conf',
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger_apache.conf.erb')),
      :require => [exec("build_apache_passenger")],
      :notify => service("apache2"),
      :alias => "passenger_apache_conf"

    a2enmod 'passenger', :require => [exec("build_passenger"), file("passenger_apache_conf"), file("passenger_apache_load")]
  end

  # Creates and enables a vhost configuration named after your application.
  # Also ensures that the <tt>000-default</tt> vhost is disabled.
  def passenger_apache_site
    file "/etc/apache2/sites-available/#{configuration[:application]}",
      :ensure => :present,
      :content => template(File.join(File.dirname(__FILE__), 'templates', 'passenger_apache.vhost.erb')),
      :notify => service("apache2"),
      :alias => "passenger_apache_vhost",
      :require => exec("a2enmod passenger")

    a2dissite '000-default', :require => file("passenger_apache_vhost")
    a2ensite configuration[:application], :require => file("passenger_apache_vhost")
  end

  def passenger_configure_gem_path
    configure(:passenger => {})
    return configuration[:passenger][:path] if configuration[:passenger][:path]
    version = begin
      configuration[:passenger][:version] || Gem::SourceIndex.from_installed_gems.find_name("passenger").last.version.to_s
    rescue
      `gem install passenger --no-ri --no-rdoc`
      `passenger-config --version`.chomp
    end
    configure(:passenger => { :path => "#{Gem.dir}/gems/passenger-#{version}" })
  end

private

  def apache_boolean(key, default = true)
    if key.nil?
      default ? 'On' : 'Off'
    else
      ((!!key) == true) ? 'On' : 'Off'
    end
  end

  def nginx_boolean(key, default = true)
    apache_boolean(key, default).downcase
  end

  def passenger_3?
    !!configuration[:passenger][:version] =~ /^3/
  end

end
