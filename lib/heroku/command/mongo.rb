module Heroku::Command
  class Mongo < BaseWithApp
    def initialize(*args)
      super

      require 'mongo'
    rescue LoadError
      error "Install the Mongo gem to use mongo commands:\nsudo gem install mongo"
    end

    def push
      display "THIS WILL REPLACE ALL DATA for #{app} ON #{heroku_mongo_uri} WITH #{local_mongo_uri} db #{local_db_name}"
      display "Are you sure? (y/n) ", false
      return unless ask.downcase == 'y'
      transfer(local_mongo_uri, heroku_mongo_uri)
    end

    def pull
      display "Replacing the #{mongoid_database || app} db at #{local_mongo_uri} with #{heroku_mongo_uri}"
      transfer(heroku_mongo_uri, local_mongo_uri)
    end

    protected
      def transfer(from, to)
        origin = make_connection(from)
        dest   = make_connection(to)

        origin.collections.each do |col|
          next if col.name =~ /^system\./

          dest.drop_collection(col.name)
          dest_col = dest.create_collection(col.name)

          count = col.size
          index = 0
          step  = count / 100000 # 1/1000 of a percent
          step  = 1 if step == 0

          col.find().each do |record|
            dest_col.insert record

            if (index += 1) % step == 0
              display(
                "\r#{"Syncing #{col.name}: %d of %d (%.2f%%)... " %
                [index, count, (index.to_f/count * 100)]}",
                false
              )
            end
          end

          display "\n done"
        end

        display "Syncing indexes...", false
        dest_index_col = dest.collection('system.indexes')
        origin_index_col = origin.collection('system.indexes')
        origin_index_col.find().each do |index|
          index['ns'] = index['ns'].sub(origin_index_col.db.name, dest_index_col.db.name)
          dest_index_col.insert index
        end
        display " done"
      end

      def heroku_mongo_uri
        config = heroku.config_vars(app)
        url    = config['MONGO_URL'] || config['MONGOHQ_URL']
        error("Could not find the MONGO_URL for #{app}") unless url
        make_uri(url)
      end
      
      def mongoid_database
        @@mongoid_database if mongoid_uri
      end
      
      def mongoid_uri
        @@mongoid_uri ||= mongoid_uri_
      end
      
      def mongoid_uri_
        # Try to use mongo development database name in mongoid.yml config file
        begin
          config = YAML::load_file('config/mongoid.yml')['development']
          @@mongoid_database = config['database']
          if @@mongoid_database
            port = config['port'] || '27017'
            host = config['host'] || 'localhost'
            username = config['username']
            password = config['password']
            uri = "mongodb://"            
            uri << "#{username}:#{password}@" if username && password
            uri << "#{host}:#{port}/#{@@mongoid_database}"
            return uri
          end
        rescue StandardError => e
        end
      end
      
      def local_mongo_uri
        url = mongoid_uri || ENV['MONGO_URL'] || "mongodb://localhost:27017/#{app}"
        make_uri(url)
      end

      def make_uri(url)
        uri = URI.parse(url.gsub('local.mongohq.com', 'mongohq.com'))
        raise URI::InvalidURIError unless uri.host
        uri
      rescue URI::InvalidURIError
        error("Invalid mongo url: #{url}")
      end

      def make_connection(uri)
        connection = ::Mongo::Connection.new(uri.host, uri.port)
        db = connection.db(uri.path.gsub(/^\//, ''))
        db.authenticate(uri.user, uri.password) if uri.user
        db
      rescue ::Mongo::ConnectionFailure
        error("Could not connect to the mongo server at #{uri}")
      end

      Help.group 'Mongo' do |group|
        group.command 'mongo:push', 'push the local mongo database'
        group.command 'mongo:pull', 'pull from the production mongo database'
      end
  end
end
