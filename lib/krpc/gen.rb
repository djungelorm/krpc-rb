require 'krpc/doc'
require 'krpc/streaming'
require 'krpc/core_extensions'

module KRPC
  module Gen
    AvailableToClassAndInstanceModuleName = "AvailableToClassAndInstance"
    
    class << self
      def service_gen_module(service_name) 
        const_get_or_create(service_name, Module.new)
      end
    
      def generate_class(service_name, class_name)
        mod = service_gen_module(service_name)
        mod.const_get_or_create(class_name) do
          Class.new(ClassBase) do
            @service_name = service_name
            class << self; attr_reader :service_name end
          end
        end
      end
      
      def generate_enum(service_name, enum_name, values)
        mod = service_gen_module(service_name)
        mod.const_get_or_create(enum_name) do
          values.map{|ev| [ev.name.underscore.to_sym, ev.value]}.to_h
        end
      end
      
      def add_rpc_method(cls, method_name, service_name, proc, *options)
        is_static = options.include? :static
        prepend_self_to_args = options.include? :prepend_self_to_args
        target_module = is_static ? cls.const_get_or_create(AvailableToClassAndInstanceModuleName, Module.new) : cls
        param_names, param_types, param_default, return_type = parse_procedure(proc)
        method_name = method_name.underscore

        transform_exceptions = Proc.new do |method_owner, &block|
          begin
            block.call
          rescue ArgumentsNumberErrorSig => err
            sig = Doc.docstring_for_method(method_owner, method_name, false)
            if prepend_self_to_args then raise ArgumentsNumberErrorSig.new(err.args_count - 1, (err.valid_params_count_range.min-1)..(err.valid_params_count_range.max-1), sig)
            else raise err.with_signature(sig) end
          rescue ArgumentErrorSig => err
            raise err.with_signature(Doc.docstring_for_method(method_owner, method_name, false))
          end
        end

        # Define method
        target_module.instance_eval do
          define_method method_name do |*args|
            transform_exceptions.call(self) do
              kwargs = args.extract_kwargs!
              args = [self] + args if prepend_self_to_args
              self.client.rpc(service_name, proc.name, args, kwargs, param_names, param_types, param_default, return_type: return_type)
            end
          end
        end
        # Add stream-constructing Proc
        unless options.include? :no_stream
          cls.stream_constructors[method_name] = Proc.new do |this, *args, **kwargs|
            transform_exceptions.call(this) do
              req_args = prepend_self_to_args ? [this] + args : args
              request  = this.client.build_request(service_name, proc.name, req_args, kwargs, param_names, param_types, param_default)
              this.client.streams_manager.create_stream(request, return_type, this.method(method_name), *args, **kwargs)
            end
          end
        end
        # Add docstring info
        Doc.add_docstring_info(is_static, cls, method_name, service_name, proc.name, param_names, param_types, param_default, return_type: return_type, xmldoc: proc.documentation)
      end
      
      private #----------------------------------
      
      def parse_procedure(proc)
        param_names = proc.parameters.map{|p| p.name.underscore}
        param_types = proc.parameters.map.with_index do |p,i|
          TypeStore.get_parameter_type(i, p.type, proc.attributes)
        end
        param_default = proc.parameters.zip(param_types).map do |param, type|
          if param.has_field?("default_argument")
            Decoder.decode(param.default_argument, type, :clientless)
          else nil
          end
        end
        return_type = if proc.has_field?("return_type")
          TypeStore.get_return_type(proc.return_type, proc.attributes)
        else nil
        end
        [param_names, param_types, param_default, return_type]
      end
    end
    
    module RPCMethodGenerator
      def include_rpc_method(method_name, service_name, procedure_name, params: [], return_type: nil, xmldoc: "", options: [])
        Gen.add_rpc_method(self.class, method_name, service_name, PB::Procedure.new(name: procedure_name, parameters: params, return_type: return_type, documentation: xmldoc), options)
      end
    end
    
    module AvailableToClassAndInstanceMethodsHandler
      def add_methods_available_to_class_and_instance
        if const_defined? AvailableToClassAndInstanceModuleName
          extend  const_get(AvailableToClassAndInstanceModuleName)
          include const_get(AvailableToClassAndInstanceModuleName)
        end
      end
    end
    
    ##
    # Base class for service-defined class types.
    class ClassBase
      extend AvailableToClassAndInstanceMethodsHandler
      include Doc::SuffixMethods
      include Streaming::StreamConstructors
      
      attr_reader :client, :remote_oid
      
      def initialize(client, remote_oid)
        @client, @remote_oid = client, remote_oid
      end
      
      alias_method :eql?, :==
      def ==(other)
        other.class == self.class and other.remote_oid == remote_oid
      end
      def hash
        remote_oid.hash
      end
      
      def self.krpc_name
        name[11..-1]
      end
    end
    
  end    
end
