require_relative '../lib/intelligence'

# amazon bedrock supports bearer-token auth. issue one from the bedrock console or use a
# long-lived AWS_BEARER_TOKEN_BEDROCK.
adapter = Intelligence::Adapter[ :bedrock ].build! do
  key     ENV[ 'AWS_BEARER_TOKEN_BEDROCK' ]
  region  ENV.fetch( 'AWS_REGION', 'us-east-1' )
  chat_options do
    model         'anthropic.claude-3-5-sonnet-20241022-v2:0'
    max_tokens    512
    temperature   0.2
  end
end

request   = Intelligence::ChatRequest.new( adapter: adapter )
response  = request.chat( ARGV[ 0 ] || 'Hello!' )

if response.success?
  puts response.result.text
else
  puts 'Error: ' + response.result.error_description
end
