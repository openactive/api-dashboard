require 'spec_helper'

describe AvailabilityCache do

  describe ".update" do
    it "stores availability if there were no issues making requests" do    
      Redis.current.del('availability')
      Redis.current.set('datasets', load_fixture("single-dataset.json"))

      result = AvailabilityCache.update
      not_updated = Redis.current.get('availability').nil?

      expect(result).to be(true).or be(false)

      if result
        expect(not_updated).to be(false)
        availability = JSON.parse(Redis.current.get('availability'))
        expect(availability.keys.size).to be > 0
        expect(availability.class).to eql(Hash)
      else
        puts "Availability cache was not updated"
        expect(not_updated).to be(true)
      end

      Redis.current.del('availability')
    end
  end

  describe ".all" do
    it "retrieves a collection of availabilities" do
      example = { "https://ourparks.org.uk/getSessions" => true }
      Redis.current.set('availability', example.to_json)

      availability = AvailabilityCache.all
      expect(availability.class).to eql(Hash)
      expect(availability.keys.size).to be > 0
      expect(availability["https://ourparks.org.uk/getSessions"]).to eql(true)

      Redis.current.del('availability')
    end
  end

end