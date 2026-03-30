require_relative 'generic/adapter'

module Intelligence
  module Ollama

    class Adapter < Generic::Adapter

      DEFAULT_BASE_URI        = 'http://localhost:11434/v1'

      schema do

        base_uri              String, default: DEFAULT_BASE_URI
        endpoint              String
        key                   String

        chat_options do
          max_tokens          Integer
          model               String
          stop                String, array: true
          stream              [ TrueClass, FalseClass ]
          temperature         Float
        end

      end

      def chat_request_uri( options = nil )
        options = merge_options( @options, build_options( options ) )
        base_uri = options[ :endpoint ] || options[ :base_uri ]
        if base_uri
          base_uri = ( base_uri.end_with?( '/' ) ? base_uri : base_uri + '/' )
          URI.join( base_uri, CHAT_COMPLETIONS_PATH )
        end
      end

    end

  end
end
