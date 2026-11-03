module Coalesce
  # Internal annotation used to record a `coalesce` declaration from the macro
  # to the `finished` hook that generates the wrapper method.
  annotation Declaration
  end

  # Declares that an instance method should have its executions coalesced.
  #
  # Concurrent calls with the same key will share a single in-flight invocation.
  #
  # Supported options:
  # - `method`: Target method symbol (e.g. `:method_name` or first argument).
  # - `key`: Key expression:
  #   - A proc literal matching method arguments: `key: ->(id : String) { "user:#{id}" }`
  #   - A symbol of an instance method: `key: :cache_key`
  #   - A static string: `key: "users_list"`
  #   - If omitted, defaults to `"ClassName#method_name(arg1, arg2)"`
  # - `ttl`: Optional cache duration (`Time::Span` or numeric milliseconds).
  # - `timeout`: Optional maximum wait time for waiting callers (`Time::Span`).
  # - `on_hit`: Optional callback symbol or proc invoked when an in-flight/cache hit occurs.
  # - `on_miss`: Optional callback symbol or proc invoked when fresh work is executed.
  #
  # ```
  # class UserClient
  #   include Coalesce
  #
  #   coalesce key: ->(id : String) { "user:#{id}" }, method: :fetch_user, ttl: 5.seconds
  #
  #   def fetch_user(id : String) : User
  #     api.get_user(id)
  #   end
  # end
  # ```
  macro coalesce(*args, **options, &block)
    {% if options[:method] || (args.size > 0 && args[0].is_a?(SymbolLiteral)) %}
      {% method = options[:method] || args[0] %}
      {% key = options[:key] || (args.size > 1 ? args[1] : nil) %}
      {% ttl = options[:ttl] %}
      {% timeout = options[:timeout] %}
      {% on_hit = options[:on_hit] %}
      {% on_miss = options[:on_miss] %}

      @[::Coalesce::Declaration(
        target: {{method}},
        key: {{key}},
        ttl: {{ttl}},
        timeout: {{timeout}},
        on_hit: {{on_hit}},
        on_miss: {{on_miss}}
      )]
      private def __coalesce_declaration_{{method.id.stringify.gsub(/[^A-Za-z0-9_]/, "_").id}}
      end
    {% else %}
      {% if block %}
        {% if args.size > 0 && options.size > 0 %}
          ::Coalesce.default_registry.execute({{args.splat}}, {{options.double_splat}}) {{block}}
        {% elsif args.size > 0 %}
          ::Coalesce.default_registry.execute({{args.splat}}) {{block}}
        {% else %}
          ::Coalesce.default_registry.execute({{options.double_splat}}) {{block}}
        {% end %}
      {% else %}
        {% if args.size > 0 && options.size > 0 %}
          ::Coalesce.default_registry.execute({{args.splat}}, {{options.double_splat}})
        {% elsif args.size > 0 %}
          ::Coalesce.default_registry.execute({{args.splat}})
        {% else %}
          ::Coalesce.default_registry.execute({{options.double_splat}})
        {% end %}
      {% end %}
    {% end %}
  end

  macro included
    # Preserve normal constructor semantics on including classes
    def self.new(*args, **options)
      instance = allocate
      instance.initialize(*args, **options)
      instance
    end

    def self.new(*args, **options, &block)
      instance = allocate
      instance.initialize(*args, **options, &block)
      instance
    end

    {% verbatim do %}
      macro finished
        {% seen_targets = [] of StringLiteral %}

        {% for decl_method in @type.methods.select { |m| m.name.stringify.starts_with?("__coalesce_declaration_") } %}
          {% decl = decl_method.annotation(::Coalesce::Declaration) %}
          {% target = decl[:target] %}
          {% target_name = target.id.stringify %}

          {% if seen_targets.includes?(target_name) %}
            {% raise "duplicate coalesce declaration for #{@type}##{target_name}" %}
          {% end %}
          {% seen_targets << target_name %}

          {% target_methods = @type.methods.select { |m| m.name == target.id } %}
          {% if target_methods.empty? %}
            {% raise "coalesce target `#{target_name}` was not found as an instance method on #{@type}" %}
          {% end %}

          {% for method in target_methods %}
            {% if method.abstract? %}
              {% raise "cannot coalesce abstract method #{@type}##{method.name}" %}
            {% end %}

            {% captured_block = method.block_arg && method.block_arg.internal_name.stringify != "" %}
            {% if captured_block && !method.block_arg.restriction %}
              {% raise "cannot wrap #{@type}##{method.name}: give the captured block parameter a type or use an anonymous `&` block" %}
            {% end %}

            {% if method.visibility == :private %}private{% elsif method.visibility == :protected %}protected{% end %} def {{method.name}}(
              {% for argument, index in method.args %}
                {% if method.splat_index && index == method.splat_index %}
                  *{{argument.internal_name}}{% if argument.restriction %} : {{argument.restriction}}{% end %},
                {% else %}
                  {% if argument.name.stringify != argument.internal_name.stringify %}{{argument.name}} {% end %}{{argument.internal_name}}{% if argument.restriction %} : {{argument.restriction}}{% end %}{% if argument.default_value %} = {{argument.default_value}}{% end %},
                {% end %}
              {% end %}
              {% if method.double_splat %}**{{method.double_splat.internal_name}}{% if method.double_splat.restriction %} : {{method.double_splat.restriction}}{% end %},{% end %}
              {% if captured_block %}&__coalesce_block : {{method.block_arg.restriction}}{% elsif method.accepts_block? %}&{% end %}
            )
              {% if decl[:key].is_a?(ProcLiteral) %}
                {% key_proc = decl[:key] %}
                {% if key_proc.args.empty? %}
                  __coalesce_key = ({{key_proc}}).call.to_s
                {% else %}
                  {% proc_call_args = [] of ASTNode %}
                  {% for parg in key_proc.args %}
                    {% match = method.args.find { |m_arg| m_arg.name.stringify == parg.name.stringify || m_arg.internal_name.stringify == parg.name.stringify } %}
                    {% if match %}
                      {% proc_call_args << match.internal_name %}
                    {% else %}
                      {% proc_call_args << parg.name %}
                    {% end %}
                  {% end %}
                  __coalesce_key = ({{key_proc}}).call({{proc_call_args.join(", ").id}}).to_s
                {% end %}
              {% elsif decl[:key].is_a?(SymbolLiteral) %}
                {% key_sym = decl[:key].id %}
                {% if method.args.empty? %}
                  __coalesce_key = self.{{key_sym}}.to_s
                {% else %}
                  {% key_methods = @type.methods.select { |m| m.name == key_sym } %}
                  {% takes_args = key_methods.empty? || key_methods.any? { |m| m.args.size > 0 || m.splat_index || m.double_splat } %}
                  {% if takes_args %}
                    __coalesce_key = self.{{key_sym}}(
                      {% for arg in method.args %}
                        {{arg.internal_name}},
                      {% end %}
                    ).to_s
                  {% else %}
                    __coalesce_key = self.{{key_sym}}.to_s
                  {% end %}
                {% end %}
              {% elsif decl[:key] != nil %}
                __coalesce_key = ({{decl[:key]}}).to_s
              {% else %}
                {% if method.args.empty? %}
                  __coalesce_key = {{@type.name.stringify}} + "#" + {{method.name.stringify}}
                {% else %}
                  __coalesce_key = {{@type.name.stringify}} + "#" + {{method.name.stringify}} + ":" + {
                    {% for arg in method.args %}
                      {{arg.internal_name}},
                    {% end %}
                  }.to_s
                {% end %}
              {% end %}

              {% if decl[:on_hit] %}
                {% if decl[:on_hit].is_a?(SymbolLiteral) %}
                  __coalesce_on_hit = ->(__k : String) {
                    {% hit_methods = @type.methods.select { |m| m.name == decl[:on_hit].id } %}
                    {% takes_arg = hit_methods.empty? || hit_methods.any? { |m| m.args.size > 0 || m.splat_index || m.double_splat } %}
                    {% if takes_arg %}
                      self.{{decl[:on_hit].id}}(__k)
                    {% else %}
                      self.{{decl[:on_hit].id}}
                    {% end %}
                    nil
                  }
                {% else %}
                  __coalesce_on_hit = ->(__k : String) {
                    ({{decl[:on_hit]}}).call(__k)
                    nil
                  }
                {% end %}
              {% else %}
                __coalesce_on_hit = nil
              {% end %}

              {% if decl[:on_miss] %}
                {% if decl[:on_miss].is_a?(SymbolLiteral) %}
                  __coalesce_on_miss = ->(__k : String) {
                    {% miss_methods = @type.methods.select { |m| m.name == decl[:on_miss].id } %}
                    {% takes_arg = miss_methods.empty? || miss_methods.any? { |m| m.args.size > 0 || m.splat_index || m.double_splat } %}
                    {% if takes_arg %}
                      self.{{decl[:on_miss].id}}(__k)
                    {% else %}
                      self.{{decl[:on_miss].id}}
                    {% end %}
                    nil
                  }
                {% else %}
                  __coalesce_on_miss = ->(__k : String) {
                    ({{decl[:on_miss]}}).call(__k)
                    nil
                  }
                {% end %}
              {% else %}
                __coalesce_on_miss = nil
              {% end %}

              ::Coalesce.coalesce(
                __coalesce_key,
                ttl: {{decl[:ttl]}},
                timeout: {{decl[:timeout]}},
                on_hit: __coalesce_on_hit,
                on_miss: __coalesce_on_miss
              ) do
                previous_def(
                  {% for argument, index in method.args %}
                    {% if method.splat_index && index == method.splat_index %}
                      {% if argument.internal_name.stringify != "" %}*{{argument.internal_name}},{% end %}
                    {% elsif !(method.splat_index && index > method.splat_index) %}
                      {{argument.internal_name}},
                    {% end %}
                  {% end %}
                  {% if method.double_splat %}**{{method.double_splat.internal_name}},{% end %}
                  {% for argument, index in method.args %}
                    {% if method.splat_index && index > method.splat_index %}
                      {{argument.name}}: {{argument.internal_name}},
                    {% end %}
                  {% end %}
                  {% if captured_block %}&__coalesce_block{% end %}
                ){% if method.accepts_block? && !captured_block %} { |*__coalesce_block_args| yield *__coalesce_block_args }{% end %}
              end
            end
          {% end %}
        {% end %}
      end
    {% end %}
  end
end
