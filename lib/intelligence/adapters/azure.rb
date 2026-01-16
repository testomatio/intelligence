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
          tool_choice               String
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

    end
  end
end
