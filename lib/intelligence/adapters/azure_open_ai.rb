require_relative 'generic/adapter'
require 'net/http'
require 'uri'
require 'json'

module Intelligence
  module AzureOpenAi
    class Adapter < Generic::Adapter
      schema do
        base_uri String, required: true
        endpoint String
        api_version String, default: '2025-01-01-preview'
        key String
        tenant_id String
        client_id String
        client_secret String
        azure_ad_tenant String
        azure_ad_client_id String
        azure_ad_client_secret String

        chat_options do
          model String, required: true
          max_tokens Integer, as: :max_completion_tokens
          max_completion_tokens Integer
          temperature Float
          top_p Float
          seed Integer
          stop String, array: true
          stream [TrueClass, FalseClass]
          frequency_penalty Float
          presence_penalty Float
          n Integer
          audio do
            voice String
            format String
          end
          logit_bias
          logprobs [TrueClass, FalseClass]
          top_logprobs Integer
          modalities String, array: true
          response_format do
            type Symbol, in: %i[text json_schema]
            json_schema
          end
          service_tier String
          stream_options do
            include_usage [TrueClass, FalseClass]
          end
          user
          tool array: true, as: :tools, &::Intelligence::Tool.schema
          tool_choice arguments: :type do
            type Symbol, in: %i[none auto required]
            function arguments: :name do
              name Symbol
            end
          end
          parallel_tool_calls [TrueClass, FalseClass]
        end
      end

      def fetch_access_token(tenant_id, client_id, client_secret)
        uri = URI("https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token")
        res = Net::HTTP.post_form(uri, {
                                    'client_id' => client_id,
                                    'client_secret' => client_secret,
                                    'scope' => 'https://cognitiveservices.azure.com/.default',
                                    'grant_type' => 'client_credentials'
                                  })
        raise res.body unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)['access_token']
      end

      def chat_request_uri(options)
        options = merge_options(@options, build_options(options))
        base_uri = options[:base_uri] || options[:endpoint]
        model = options.dig(:chat_options, :model)
        api_version = options[:api_version]

        raise ArgumentError.new('An Azure OpenAI base_uri is required to build an Azure OpenAI chat request.') \
          if base_uri.nil?
        raise ArgumentError.new('A model is required to build an Azure OpenAI chat request.') \
          if model.nil?

        "#{base_uri}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}"
      end

      def chat_request_headers(options = nil)
        options = merge_options(@options, build_options(options))
        result = {}

        azure_ad_tenant = options[:azure_ad_tenant]
        azure_ad_client_id = options[:azure_ad_client_id]
        azure_ad_client_secret = options[:azure_ad_client_secret]

        if azure_ad_tenant && azure_ad_client_id && azure_ad_client_secret
          token = fetch_access_token(azure_ad_tenant, azure_ad_client_id, azure_ad_client_secret)
          result['Authorization'] = "Bearer #{token}"
        else
          tenant_id = options[:tenant_id]
          client_id = options[:client_id]
          client_secret = options[:client_secret]

          if tenant_id && client_id && client_secret
            token = fetch_access_token(tenant_id, client_id, client_secret)
            result['Authorization'] = "Bearer #{token}"
          else
            key = options[:key]
            raise ArgumentError.new('An Azure OpenAI key is required to build an Azure OpenAI chat request.') \
              if key.nil?

            result['api-key'] = key
          end
        end
        result['Content-Type'] = 'application/json'
        result
      end

      def chat_request_body(conversation, options = nil)
        tools = options&.delete(:tools) || []
        options = merge_options(@options, build_options(options))

        chat_options = options[:chat_options]&.dup || {}
        chat_options.delete(:model)

        super(conversation, { tools: tools }.merge(options.merge(chat_options: chat_options)))
      end
    end
  end
end
