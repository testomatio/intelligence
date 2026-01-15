require_relative 'generic'

module Intelligence
  module Azure
    class Adapter < Generic::Adapter
      schema do
        # normalized properties, used by all endpoints
        base_uri String
        endpoint String
        key String
        api_version String, required: true, default: '2025-01-01-preview'

        # properties for generative text endpoints
        chat_options do
          # normalized properties for openai generative text endpoint
          model                     String, requried: true
          max_tokens                Integer, in: (0...)
          temperature               Float, in: (0..1)
          top_p                     Float, in: (0..1)
          seed                      Integer
          stop                      String, array: true
          stream                    [TrueClass, FalseClass]

          frequency_penalty         Float, in: (-2..2)
          presence_penalty          Float, in: (-2..2)

          modalities                String, array: true
          response_format do
            # 'text' and 'json_schema' are the only supported types
            type Symbol, in: %i[text json_schema]
            json_schema
          end

          # tools
          tool                      array: true, as: :tools, &Tool.schema
          # tool choice configuration
          #
          # `tool_choice :none`
          # or
          # ```
          # tool_choice :function do
          #   function :my_function
          # end
          # ```
          tool_choice               arguments: :type do
            type                    Symbol, in: %i[none auto required]
            function                arguments: :name do
              name                  Symbol
            end
          end
          # the parallel_tool_calls parameter is only allowed when 'tools' are specified
          parallel_tool_calls [TrueClass, FalseClass]
        end
      end

      def chat_request_uri(options = nil)
        options = merge_options(@options, build_options(options))
        base_uri = options[:base_uri] || options[:endpoint]
        api_version = options[:api_version]

        raise ArgumentError, 'An Azure base_uri is required to build an Azure chat request.' if base_uri.nil?

        # Remove trailing slash if present
        base_uri = base_uri.chomp('/')

        # New format: /api/v1/chat/completions
        "#{base_uri}/api/v1/chat/completions?api-version=#{api_version}"
      end

      def chat_request_headers(options = {})
        options = merge_options(@options, build_options(options))
        key = options[:key]

        raise ArgumentError, 'An Azure key is required to build an Azure request.' if key.nil?

        {
          'Content-Type' => 'application/json',
          'Authorization' => "Bearer #{key}"
        }
      end

      def chat_request_body(conversation, options = nil)
        tools = options&.delete(:tools) || []
        options = merge_options(@options, build_options(options))

        chat_options = options[:chat_options]&.dup || {}

        # Transform tool_choice from schema format to API format
        if chat_options[:tool_choice].is_a?(Hash)
          tool_choice = chat_options[:tool_choice]
          if tool_choice[:function] && tool_choice[:function][:name]
            # Convert to function-specific format: {"type": "function", "function": {"name": "..."}}
            chat_options[:tool_choice] = {
              type: 'function',
              function: { name: tool_choice[:function][:name].to_s }
            }
          else
            # Convert to simple string: "auto", "none", "required"
            chat_options[:tool_choice] = tool_choice[:type]&.to_s
          end
        end

        super(conversation, { tools: tools }.merge(options.merge(chat_options: chat_options)))
      end
    end
  end
end
