require 'app/services/connection_builder'
require 'app/services/publisher_update'

module Citygram::Workers
  class PublisherPoll
    include Sidekiq::Worker
    sidekiq_options retry: 5

    MAX_PAGE_NUMBER = 10
    NEXT_PAGE_HEADER = 'Next-Page'.freeze

    def perform(publisher_id, url, page_number = 1)
      # fetch publisher record or raise
      publisher = Publisher.first!(id: publisher_id)
      begin
        # prepare a connection for the given url
        connection = Citygram::Services::ConnectionBuilder.json("request.publisher.#{publisher.id}", url: url)

        # execute the request or raise
        response = connection.get

        # save any new events
        feature_collection = response.body
        new_events = []
        if !(ENV["SMS_ENABLED"]=="false")
          new_events = Citygram::Services::PublisherUpdate.call(feature_collection.fetch('features'), publisher)
        else
          Citygram::App.logger.info("Suppressing SMS per env setting")
        end
        publisher.close_outage

        # OPTIONAL PAGINATION:
        #
        # iff successful to this point, and a next page is given
        # queue up a job to retrieve the next page
        #
        next_page = response.headers[NEXT_PAGE_HEADER]
        if new_events.any? && valid_next_page?(next_page, url) && page_number < MAX_PAGE_NUMBER
          self.class.perform_async(publisher_id, next_page, page_number + 1)
        end
      rescue Faraday::ClientError => e
        Citygram::App.logger.info("Recording outage for #{publisher.title} for #{publisher.city}")
        publisher.open_outage(e)
      end
    end

    private

    def valid_next_page?(next_page, current_page)
      return false unless next_page.present?

      next_page = URI.parse(next_page)
      current_page = URI.parse(current_page)

      next_page.host == current_page.host
    end
  end
end
