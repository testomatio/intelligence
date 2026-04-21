module Intelligence
  module Bedrock
    module ChatResponseMethods

      def chat_result_attributes( response )
        return nil unless response.success?

        response_json = JSON.parse( response.body, symbolize_names: true ) rescue nil
        return nil if response_json.nil?

        result = {}
        result_choice = { end_reason: translate_stop_reason( response_json[ :stopReason ] ) }

        output_message = response_json.dig( :output, :message )
        if output_message && output_message[ :content ].is_a?( Array )
          contents = []
          output_message[ :content ].each do | block |
            translated = from_bedrock_content_block( block )
            contents << translated if translated
          end

          unless contents.empty?
            result_choice[ :message ] = {
              role:     ( output_message[ :role ] || 'assistant' ).to_s,
              contents: contents
            }
          end
        end

        result[ :choices ] = [ result_choice ]

        metrics_json = response_json[ :usage ]
        unless metrics_json.nil?
          metrics = {
            input_tokens:   metrics_json[ :inputTokens ],
            output_tokens:  metrics_json[ :outputTokens ]
          }.compact
          result[ :metrics ] = metrics unless metrics.empty?
        end

        result
      end

      def chat_result_error_attributes( response )
        error_type, error_description = translate_response_status( response.status )

        parsed_body = JSON.parse( response.body, symbolize_names: true ) rescue nil
        if parsed_body.is_a?( Hash )
          error_code    = parsed_body[ :__type ] || parsed_body[ :code ] || error_type.to_s
          error_message = parsed_body[ :message ] || parsed_body[ :Message ] || error_description
          {
            error_type:         error_type.to_s,
            error:              error_code.to_s,
            error_description:  error_message
          }
        else
          {
            error_type:         error_type.to_s,
            error_description:  error_description
          }
        end
      end

      def stream_result_chunk_attributes( context, chunk )
        context ||= {}
        decoder   = context[ :decoder ] ||= begin
          require 'aws-eventstream'
          Aws::EventStream::Decoder.new
        end
        choices   = context[ :choices ] || Array.new( 1, { message: { contents: [] } } )
        metrics   = context[ :metrics ] || { input_tokens: 0, output_tokens: 0 }
        role      = context[ :role ] || 'assistant'
        end_reason = context[ :end_reason ]

        # reduce the existing contents to type-only entries, so deltas applied below
        # contain only the new data for this chunk. merge_choices! then concatenates
        # those deltas onto the accumulated state.
        contents = ( choices.first[ :message ][ :contents ] || [] ).map do | content |
          { type: content[ :type ] }
        end

        message_obj, eof = decoder.decode_chunk( chunk )
        while message_obj
          event_type    = message_obj.headers[ ':event-type' ]&.value
          message_type  = message_obj.headers[ ':message-type' ]&.value
          payload_raw   = message_obj.payload.read
          payload_raw.force_encoding( Encoding::UTF_8 ) if payload_raw

          data = JSON.parse( payload_raw, symbolize_names: true ) rescue nil

          if message_type == 'exception'
            context[ :exception ] = {
              error_type:         ( event_type || 'exception' ),
              error:              ( event_type || 'exception' ),
              error_description:  data.is_a?( Hash ) ? ( data[ :message ] || data[ :Message ] ) : nil
            }.compact
            break
          end

          if data.is_a?( Hash )
            case event_type
            when 'messageStart'
              role = data[ :role ].to_s if data[ :role ]
            when 'contentBlockStart'
              index = data[ :contentBlockIndex ] || contents.size
              ensure_content_slot( contents, index )
              if ( tool_use = data.dig( :start, :toolUse ) )
                contents[ index ] = {
                  type:             :tool_call,
                  tool_call_id:     tool_use[ :toolUseId ],
                  tool_name:        tool_use[ :name ],
                  tool_parameters:  ''
                }
              end
            when 'contentBlockDelta'
              index = data[ :contentBlockIndex ] || ( contents.empty? ? 0 : contents.size - 1 )
              ensure_content_slot( contents, index )
              apply_stream_delta!( contents, index, data[ :delta ] )
            when 'contentBlockStop'
              # nop - tool_parameters remain as a partial-json string for the caller
            when 'messageStop'
              end_reason = translate_stop_reason( data[ :stopReason ] )
            when 'metadata'
              if ( usage = data[ :usage ] )
                metrics[ :input_tokens ]  = usage[ :inputTokens ]  if usage[ :inputTokens ]
                metrics[ :output_tokens ] = usage[ :outputTokens ] if usage[ :outputTokens ]
              end
            end
          end

          break if eof
          message_obj, eof = decoder.decode_chunk( nil )
        end

        choices_delta = [ {
          end_reason: end_reason,
          message:    { role: role, contents: contents }
        } ]

        context[ :metrics ]     = metrics
        context[ :role ]        = role
        context[ :end_reason ]  = end_reason
        context[ :choices ]     = merge_choices!( choices, choices_delta )

        [ context, { choices: choices_delta } ]
      end

      def stream_result_attributes( context )
        { choices: context[ :choices ], metrics: context[ :metrics ] }
      end

      alias_method :stream_result_error_attributes, :chat_result_error_attributes

    private

      def from_bedrock_content_block( block )
        if ( text = block[ :text ] )
          { type: :text, text: text }
        elsif ( tool_use = block[ :toolUse ] )
          {
            type:             :tool_call,
            tool_call_id:     tool_use[ :toolUseId ],
            tool_name:        tool_use[ :name ],
            tool_parameters:  tool_use[ :input ]
          }
        elsif ( reasoning = block[ :reasoningContent ] )
          if ( reasoning_text = reasoning[ :reasoningText ] )
            {
              type:                     :thought,
              text:                     reasoning_text[ :text ],
              :'bedrock/signature' =>   reasoning_text[ :signature ]
            }.compact
          elsif reasoning[ :redactedContent ]
            {
              type:                 :cipher_thought,
              :'bedrock/item' =>    block.to_json
            }
          end
        end
      end

      def ensure_content_slot( contents, index )
        contents.fill( {}, contents.size, ( index + 1 - contents.size ) ) if contents.size <= index
      end

      def apply_stream_delta!( contents, index, delta )
        return unless delta.is_a?( Hash )

        current = contents[ index ] ||= {}

        if delta.key?( :text )
          current[ :type ] = :text
          current[ :text ] = ( current[ :text ] || '' ) + delta[ :text ].to_s
        elsif ( tool_use = delta[ :toolUse ] )
          partial = tool_use[ :input ]
          partial = partial[ :partial_json ] if partial.is_a?( Hash )
          current[ :type ] = :tool_call
          current[ :tool_parameters ] = ( current[ :tool_parameters ] || '' ) + partial.to_s
        elsif ( reasoning = delta[ :reasoningContent ] )
          if reasoning.key?( :text )
            current[ :type ] = :thought
            current[ :text ] = ( current[ :text ] || '' ) + reasoning[ :text ].to_s
          elsif reasoning.key?( :signature )
            current[ :type ] = :thought
            current[ :'bedrock/signature' ] = reasoning[ :signature ]
          elsif reasoning.key?( :redactedContent )
            current[ :type ] = :cipher_thought
            current[ :'bedrock/item' ] = {
              reasoningContent: { redactedContent: reasoning[ :redactedContent ] }
            }.to_json
          end
        end
      end

      def translate_stop_reason( reason )
        case reason&.to_s
          when 'end_turn'               then :ended
          when 'tool_use'               then :tool_called
          when 'max_tokens'             then :token_limit_exceeded
          when 'stop_sequence'          then :end_sequence_encountered
          when 'guardrail_intervened',
               'content_filtered'       then :filtered
          else reason&.to_sym
        end
      end

      def translate_response_status( status )
        case status
          when 400 then [ :invalid_request_error, 'There was an issue with the format or content of your request.' ]
          when 401 then [ :authentication_error,  "There's an issue with your API key." ]
          when 403 then [ :permission_error,      'Your credentials do not have permission to use the specified resource.' ]
          when 404 then [ :not_found_error,       'The requested resource was not found.' ]
          when 413 then [ :request_too_large,     'Request exceeds the maximum allowed number of bytes.' ]
          when 422 then [ :invalid_request_error, 'There was an issue with the format or content of your request.' ]
          when 424 then [ :invalid_request_error, 'The request could not be processed by the model.' ]
          when 429 then [ :rate_limit_error,      'Your account has hit a rate limit.' ]
          when 500, 502, 503 then [ :api_error,   "An unexpected error occurred internal to the provider's systems." ]
          when 529 then [ :overloaded_error,      "The provider's server is temporarily overloaded." ]
          else          [ :unknown_error,         'An unknown error occurred.' ]
        end
      end

    end
  end
end
