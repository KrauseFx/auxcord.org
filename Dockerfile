FROM ruby:3.0.2

#RUN bundle config --global frozen 1

WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 4567
CMD ["bundle", "exec", "ruby", "server.rb"]