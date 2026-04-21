require_relative '../lib/intelligence'

adapter = Intelligence::Adapter[ :bedrock ].build! do
  key     ENV[ 'AWS_BEARER_TOKEN_BEDROCK' ]
  region  ENV.fetch( 'AWS_REGION', 'us-east-1' )
  chat_options do
    model         'anthropic.claude-3-5-sonnet-20241022-v2:0'
    max_tokens    1024
    stream        true
  end
end

request   = Intelligence::ChatRequest.new( adapter: adapter )
response  = request.stream( ARGV[ 0 ] || 'Hello!' ) do | request |
  request.receive_result do | result |
    print result.text
    print "\n" if result.choices.first.end_reason
  end
end

puts 'Error: ' + response.result.error_description unless response.success?
