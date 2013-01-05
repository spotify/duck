module ModuleHelper
  class StepError < Exception
  end

  class Step
    attr_accessor :name, :disable_hook

    def initialize(name, params={})
      @name = name
      @disable_hook = params[:disable_hook] || false
    end
  end

  module ClassMethods
    def step(name, params={})
      @steps << Step.new(name, params)
    end

    def steps
      @steps
    end
  end

  def self.included(mod)
    mod.extend ClassMethods
    mod.instance_variable_set :@steps, []
  end

  def pre_hook(name); end
  def post_hook(name); end
  def final_hook(); end

  def execute
    self.class.steps.each do |step|
      name = step.name.to_s.gsub '_', '-'

      log.info "#{name}: running"
      pre_hook name unless step.disable_hook

      begin
        self.method(step.name).call
      rescue StepError
        log.error "#{name}: #{$!}"
        return
      end

      post_hook name unless step.disable_hook
      log.info "#{name}: done"
    end

    final_hook

    # run fixes for finalizing the setup.
    return 0
  end
end
