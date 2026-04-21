require_relative 'chat_request_methods'
require_relative 'chat_response_methods'

module Intelligence
  module Bedrock
    class Adapter < Adapter::Base

      DEFAULT_HOST_TEMPLATE = 'https://bedrock-runtime.%<region>s.amazonaws.com'.freeze

      schema do

        # bearer token for Amazon Bedrock; or falls back to ENV[ 'AWS_BEARER_TOKEN_BEDROCK' ]
        key                 String

        # aws region of the bedrock endpoint; or falls back to ENV[ 'AWS_REGION' ] /
        # ENV[ 'AWS_DEFAULT_REGION' ]
        region              String

        # optional override of the endpoint root; when set the adapter will not inject a region
        # into the host. useful for vpc endpoints and custom bedrock-compatible services
        base_uri            String

        chat_options do

          # normalized properties for bedrock converse endpoint
          model             String, required: true
          max_tokens        Integer, in: (1...)
          temperature       Float,   in: 0.0..1.0
          top_p             Float,   in: (0..1)
          stop              String,  array: true, as: :stop_sequences
          stream            [ TrueClass, FalseClass ]

          # bedrock variant of normalized properties
          stop_sequences    String, array: true

          # reasoning is emitted into additionalModelRequestFields.reasoning_config
          # for anthropic claude models hosted on bedrock. other families use
          # additional_model_request_fields directly.
          reasoning do
            type            Symbol,  default: :enabled
            budget_tokens   Integer, in: (1024...)
            # normalized attribute name
            budget          as: :budget_tokens, in: (1024...)
          end

          # tool calling
          tool              array: true, as: :tools, &Tool.schema
          # bedrock tool choice configuration; note that :none is not supported (omit tools to
          # disable tool calling)
          #
          # `tool_choice :any`
          # or
          # `tool_choice :tool do name :my_tool end`
          tool_choice       arguments: :type do
            type            Symbol, in: [ :auto, :any, :tool ]
            # only set when type = :tool
            name            String
          end

          # bedrock-specific features
          guardrail         as: :guardrail_config do
            identifier                String, as: :guardrailIdentifier
            version                   String, as: :guardrailVersion
            trace                     Symbol, in: [ :enabled, :disabled ]
            stream_processing_mode    Symbol, in: [ :sync, :async ], as: :streamProcessingMode
          end
          performance_config  do
            latency           Symbol, in: [ :standard, :optimized ]
          end
          additional_model_request_fields         Hash
          additional_model_response_field_paths   String, array: true
          prompt_variables                        Hash
          request_metadata                        Hash

        end

      end

      include ChatRequestMethods
      include ChatResponseMethods

    end
  end
end
