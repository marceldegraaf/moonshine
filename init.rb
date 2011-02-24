if Rails::VERSION::MAJOR > 2
  # Make app/manifests NOT be eagerly loaded
  Rails.configuration.eager_load_paths = ['app/models', 'app/controllers', 'app/helpers']
end
