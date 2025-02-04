module CachedResource
  # The Caching module is included in ActiveResource and
  # handles caching and recaching of responses.
  module Caching
    extend ActiveSupport::Concern

    included do
      class << self
        alias_method :find_without_cache, :find
        alias_method :find, :find_with_cache
      end
    end

    module ClassMethods
      # Find a resource using the cache or resend the request
      # if :reload is set to true or caching is disabled.
      def find_with_cache(*arguments)
        arguments << {} unless arguments.last.is_a?(Hash)
        should_reload = arguments.last.delete(:reload) || !cached_resource.enabled
        arguments.pop if arguments.last.empty?
        key = cache_key(arguments)

        should_reload ? find_via_reload(key, *arguments) : find_via_cache(key, *arguments)
      end

      # Clear the cache.
      def clear_cache
        cache_clear
      end

      private

      # Try to find a cached response for the given key.  If
      # no cache entry exists, send a new request.
      def find_via_cache(key, *arguments)
        cache_read(key) || find_via_reload(key, *arguments)
      end

      # Re/send the request to fetch the resource. Cache the response
      # for the request.
      def find_via_reload(key, *arguments)
        object = find_without_cache(*arguments)
        cache_collection_synchronize(object, *arguments) if cached_resource.collection_synchronize
        cache_write(key, object)
        cache_read(key)
      end

      # If this is a pure, unadulterated "all" request
      # write cache entries for all its members
      # otherwise update an existing collection if possible.
      def cache_collection_synchronize(object, *arguments)
        if object.is_a? Enumerable
          update_singles_cache(object)
          # update the collection only if this is a subset of it
          update_collection_cache(object) unless is_collection?(*arguments)
        else
          update_collection_cache(object)
        end
      end

      # Update the cache of singles with an array of updates.
      def update_singles_cache(updates)
        updates = Array(updates)
        updates.each { |object| cache_write(cache_key(object.send(primary_key)), object) }
      end

      # Update the "mother" collection with an array of updates.
      def update_collection_cache(updates)
        updates = Array(updates)
        collection = cache_read(cache_key(cached_resource.collection_arguments))

        if collection && !updates.empty?
          index = collection.index_by { |object| object.send(primary_key); }
          updates.each { |object| index[object.send(primary_key)] = object }
          cache_write(cache_key(cached_resource.collection_arguments), index.values)
        end
      end

      # Determine if the given arguments represent
      # the entire collection of objects.
      def is_collection?(*arguments)
        arguments == cached_resource.collection_arguments
      end

      # Read a entry from the cache for the given key.
      def cache_read(key)
        object = cached_resource.cache.read(key).try do |json_cache|
          json = ActiveSupport::JSON.decode(json_cache)

          unless json.nil?
            cache = json_to_object(json)
            if cache.respond_to?(:key) && cache.key?(:pagination_link_headers)
              restored = cache[:elements].map { |record| full_dup(record) }
              next restored unless respond_to?(:collection_parser)

              collection_parser.new({ elements: restored, pagination_link_headers: cache[:pagination_link_headers] })

            elsif cache.is_a? Enumerable
              restored = cache.map { |record| full_dup(record) }
              next restored unless respond_to?(:collection_parser)

              collection_parser.new(restored)
            else
              full_dup(cache)
            end
          end
        end
        object && cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} READ #{key}")
        object
      end

      # Write an entry to the cache for the given key and value.
      def cache_write(key, object)
        result = cached_resource.cache.write(key, object_to_json(object), race_condition_ttl: cached_resource.race_condition_ttl, expires_in: cached_resource.generate_ttl)
        result && cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} WRITE #{key}")
        result
      end

      # Clear the cache.
      def cache_clear
        cached_resource.cache.clear.tap do |_result|
          cached_resource.logger.info("#{CachedResource::Configuration::LOGGER_PREFIX} CLEAR")
        end
      end

      # Generate the request cache key.
      def cache_key(*arguments)
        "#{name.parameterize.tr('-', '/')}/#{arguments.join('/')}".downcase.delete(' ')
      end

      # Make a full duplicate of an ActiveResource record.
      # Currently just dups the record then copies the persisted state.
      def full_dup(record)
        record.dup.tap do |o|
          o.instance_variable_set(:@persisted, record.persisted?)
        end
      end

      def json_to_object(json)
        if json.respond_to?(:key) && json.key?('pagination_link_headers')
          elements = json['elements'].map do |attrs|
            new(attrs['object'].merge(attrs['prefix_options']), attrs['persistence'])
          end
          {
            pagination_link_headers: json['pagination_link_headers'],
            elements: elements
          }
        elsif json.is_a? Array
          json.map do |attrs|
            new(attrs['object'].merge(attrs['prefix_options']), attrs['persistence'])
          end
        else
          new(json['object'].merge(json['prefix_options']), json['persistence'])
        end
      end

      def object_to_json(object)
        if object.instance_of?(ShopifyAPI::PaginatedCollection)
          {
            pagination_link_headers: object.pagination_link_headers,
            elements: object.map { |o| { object: o, persistence: o.persisted?, prefix_options: o.prefix_options } }
          }.to_json
        elsif object.is_a? Enumerable
          object.map { |o| { object: o, persistence: o.persisted?, prefix_options: o.prefix_options } }.to_json
        elsif object.nil?
          nil.to_json
        else
          { object: object, persistence: object.persisted?, prefix_options: object.prefix_options }.to_json
        end
      end
    end
  end
end
