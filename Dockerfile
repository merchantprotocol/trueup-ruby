# Test image: installs the SDK and runs its tests (live tests need TRUEUP_API_KEY).
FROM ruby:3.3-slim
WORKDIR /sdk
COPY Gemfile trueup.gemspec ./
COPY lib/trueup/version.rb lib/trueup/version.rb
RUN bundle install --quiet
COPY . .
CMD ["bundle", "exec", "rake", "test", "TESTOPTS=-v"]
