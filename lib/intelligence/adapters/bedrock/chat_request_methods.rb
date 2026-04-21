require 'cgi'

module Intelligence
  module Bedrock
    module ChatRequestMethods

      SUPPORTED_IMAGE_TYPES     = %w[ image/jpeg image/png image/gif image/webp ].freeze
      SUPPORTED_DOCUMENT_TYPES  = {
        'application/pdf'   => 'pdf',
        'text/csv'          => 'csv',
        'application/msword'=> 'doc',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
        'application/vnd.ms-excel' => 'xls',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
        'text/html'         => 'html',
        'text/plain'        => 'txt',
        'text/markdown'     => 'md'
      }.freeze

      # inference config keys that need to be lifted out of the top-level chat_options
      # hash into the nested inferenceConfig object
      INFERENCE_CONFIG_KEYS = %i[ max_tokens temperature top_p stop_sequences ].freeze

      def chat_request_uri( options = nil )
        options       = merge_options( @options, build_options( options ) )
        region        = options[ :region ] || ENV[ 'AWS_REGION' ] || ENV[ 'AWS_DEFAULT_REGION' ]
        model         = options.dig( :chat_options, :model )
        streaming     = !!options.dig( :chat_options, :stream )

        raise ArgumentError, 'A :model is required in chat_options for a Bedrock chat request.' \
          if model.nil? || model.empty?

        base_uri = options[ :base_uri ]
        if base_uri.nil? || base_uri.empty?
          raise ArgumentError, 'A :region (or AWS_REGION / AWS_DEFAULT_REGION env) is required ' \
                               'for a Bedrock chat request.' if region.nil? || region.empty?
          base_uri = format( Adapter::DEFAULT_HOST_TEMPLATE, region: region )
        end
        base_uri = base_uri.chomp( '/' )

        endpoint = streaming ? 'converse-stream' : 'converse'
        "#{base_uri}/model/#{CGI.escape( model )}/#{endpoint}"
      end

      def chat_request_headers( options = nil )
        options = merge_options( @options, build_options( options ) )
        key     = options[ :key ] || ENV[ 'AWS_BEARER_TOKEN_BEDROCK' ]

        raise ArgumentError, 'A :key (or AWS_BEARER_TOKEN_BEDROCK env) is required to build a ' \
                             'Bedrock chat request.' if key.nil? || key.empty?

        {
          'Content-Type'  => 'application/json',
          'Authorization' => "Bearer #{key}"
        }
      end

      def chat_request_body( conversation, options = nil )
        tools     = options&.delete( :tools ) || []
        options   = merge_options( @options, build_options( options ) )

        chat_opts = ( options[ :chat_options ] || {} ).dup
        chat_opts.delete( :model )
        chat_opts.delete( :stream )
        reasoning           = chat_opts.delete( :reasoning )
        extra_request       = chat_opts.delete( :additional_model_request_fields )
        extra_response_paths = chat_opts.delete( :additional_model_response_field_paths )
        prompt_variables    = chat_opts.delete( :prompt_variables )
        request_metadata    = chat_opts.delete( :request_metadata )
        guardrail           = chat_opts.delete( :guardrail_config )
        performance_config  = chat_opts.delete( :performance_config )
        tool_choice         = chat_opts.delete( :tool_choice )
        existing_tools      = chat_opts.delete( :tools ) || []

        inference_config = {}
        INFERENCE_CONFIG_KEYS.each do | key |
          value = chat_opts.delete( key )
          inference_config[ inference_config_key( key ) ] = value unless value.nil?
        end

        result = {}
        result[ :messages ] = build_messages( conversation )

        system_message = to_system_message( conversation[ :system_message ] )
        result[ :system ] = system_message unless system_message.nil?

        result[ :inferenceConfig ] = inference_config unless inference_config.empty?

        all_tools       = ( existing_tools + tools )
        tool_config     = build_tool_config( all_tools, tool_choice )
        result[ :toolConfig ] = tool_config if tool_config

        extra_request_fields = extra_request.is_a?( Hash ) ? Utilities.deep_dup( extra_request ) : {}
        if reasoning && !reasoning.empty?
          extra_request_fields[ :reasoning_config ] = {
            type:           ( reasoning[ :type ] || :enabled ).to_s,
            budget_tokens:  reasoning[ :budget_tokens ]
          }.compact
        end
        result[ :additionalModelRequestFields ] = extra_request_fields unless extra_request_fields.empty?

        result[ :additionalModelResponseFieldPaths ] = extra_response_paths \
          if extra_response_paths && !extra_response_paths.empty?
        result[ :promptVariables ] = prompt_variables if prompt_variables && !prompt_variables.empty?
        result[ :requestMetadata ] = request_metadata if request_metadata && !request_metadata.empty?
        result[ :guardrailConfig ] = guardrail if guardrail && !guardrail.empty?

        if performance_config && !performance_config.empty?
          result[ :performanceConfig ] = performance_config.transform_values do | v |
            v.is_a?( Symbol ) ? v.to_s : v
          end
        end

        JSON.generate( result )
      end

      def chat_request_tools_attributes( tools )
        properties_array_to_object = lambda do | properties |
          return nil unless properties&.any?
          object   = {}
          required = []
          properties.each do | property |
            property = property.dup
            name     = property.delete( :name )
            required << name if property.delete( :required )
            if property[ :properties ]&.any?
              property_properties, property_required =
                properties_array_to_object.call( property[ :properties ] )
              property[ :properties ] = property_properties
              property[ :required ] = property_required if property_required.any?
            end
            object[ name ] = property
          end
          [ object, required.compact ]
        end

        tools&.map do | tool |
          input_schema = { type: 'object' }
          if tool[ :properties ]&.any?
            properties_object, properties_required =
              properties_array_to_object.call( tool[ :properties ] )
            input_schema[ :properties ] = properties_object
            input_schema[ :required ]   = properties_required if properties_required.any?
          end
          {
            toolSpec: {
              name:         tool[ :name ],
              description:  tool[ :description ],
              inputSchema:  { json: input_schema }
            }.compact
          }
        end
      end

    private

      def inference_config_key( key )
        case key
          when :max_tokens      then :maxTokens
          when :temperature     then :temperature
          when :top_p           then :topP
          when :stop_sequences  then :stopSequences
          else key
        end
      end

      def build_messages( conversation )
        result   = []
        messages = conversation[ :messages ] || []
        length   = messages.length

        index = 0
        while index < length
          message = messages[ index ]
          index += 1
          next if message.nil?

          # bedrock, like anthropic, rejects two consecutive messages with the same role;
          # coalesce them by copying the look-ahead contents into the first and nilling
          # the subsequent ones
          look_ahead = index
          while look_ahead < length
            ahead = messages[ look_ahead ]
            if ahead && ahead[ :role ] == message[ :role ]
              message[ :contents ] =
                ( message[ :contents ] || [] ) + ( ahead[ :contents ] || [] )
              messages[ look_ahead ] = nil
              look_ahead += 1
            else
              break
            end
          end

          content_blocks = []
          message[ :contents ]&.each do | content |
            block = to_bedrock_content_block( content )
            content_blocks << block if block
          end

          next if content_blocks.empty?
          result << { role: message[ :role ], content: content_blocks }
        end

        result
      end

      def to_bedrock_content_block( content )
        case content[ :type ]
        when :text
          { text: content[ :text ] }
        when :thought
          signature = content[ :'bedrock/signature' ]
          if signature && !signature.empty?
            { reasoningContent: { reasoningText: { text: content[ :text ], signature: signature } } }
          end
        when :cipher_thought
          item = content[ :'bedrock/item' ]
          if item && !item.empty?
            parsed = JSON.parse( item, symbolize_names: true ) rescue nil
            parsed
          end
        when :binary
          content_type = content[ :content_type ]
          bytes        = content[ :bytes ]

          raise UnsupportedContentError.new(
            :bedrock,
            'requires binary content to include content type and (packed) bytes'
          ) unless content_type && bytes

          if SUPPORTED_IMAGE_TYPES.include?( content_type )
            {
              image: {
                format: content_type.split( '/' ).last,
                source: { bytes: Base64.strict_encode64( bytes ) }
              }
            }
          elsif ( format = SUPPORTED_DOCUMENT_TYPES[ content_type ] )
            {
              document: {
                format: format,
                name:   ( content[ :name ] || 'document' ),
                source: { bytes: Base64.strict_encode64( bytes ) }
              }
            }
          else
            raise UnsupportedContentError.new(
              :bedrock,
              "does not support content of type '#{content_type}'"
            )
          end
        when :file
          raise UnsupportedContentError.new(
            :bedrock,
            'does not support file content by uri; please provide binary bytes instead'
          )
        when :tool_call
          tool_parameters = content[ :tool_parameters ]
          tool_parameters = {} if tool_parameters.nil? ||
                                  ( tool_parameters.is_a?( String ) && tool_parameters.empty? )
          if tool_parameters.is_a?( String )
            tool_parameters = JSON.parse( tool_parameters ) rescue {}
          end
          {
            toolUse: {
              toolUseId:  content[ :tool_call_id ],
              name:       content[ :tool_name ],
              input:      tool_parameters
            }
          }
        when :tool_result
          tool_result = content[ :tool_result ]
          tool_content = if tool_result.is_a?( Hash )
            [ { json: tool_result } ]
          else
            [ { text: tool_result.to_s } ]
          end
          {
            toolResult: {
              toolUseId:  content[ :tool_call_id ],
              content:    tool_content,
              status:     'success'
            }
          }
        when :web_search_call, :web_reference
          nil
        else
          raise UnsupportedContentError.new(
            :bedrock,
            "does not support content of type '#{content[ :type ]}'"
          )
        end
      end

      def to_system_message( system_message )
        return nil if system_message.nil?

        blocks = []
        system_message[ :contents ]&.each do | content |
          blocks << { text: content[ :text ] } if content[ :type ] == :text && content[ :text ]
        end
        blocks.empty? ? nil : blocks
      end

      def build_tool_config( tools, tool_choice )
        tool_specs = chat_request_tools_attributes( tools ) || []
        tool_specs = tool_specs.reject( &:nil? )
        return nil if tool_specs.empty?

        config = { tools: tool_specs }

        if tool_choice.is_a?( Hash )
          type = tool_choice[ :type ]&.to_sym
          case type
          when :auto
            config[ :toolChoice ] = { auto: {} }
          when :any
            config[ :toolChoice ] = { any: {} }
          when :tool
            name = tool_choice[ :name ]
            config[ :toolChoice ] = { tool: { name: name } } if name
          end
        end

        config
      end

    end
  end
end
