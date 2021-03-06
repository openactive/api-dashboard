require 'spec_helper'

describe DatasetSummary do

  let(:summary) {
    example = { 
      "example/opendata" => { "title" => "dataset title", "data-url" => "http://www.example.com" },
      "newexample/opendata" => { "title" => "other dataset", "data-url" => "http://www.newexample.com" }
    }
    Redis.current.set('datasets', example.to_json)
    DatasetSummary.new("example/opendata")
  }

  before(:each) do
    Redis.current.hdel("example/opendata", "summary_last_updated")
    Redis.current.hdel("example/opendata", "summary_last_attempt")
    Redis.current.hdel("example/opendata", "summary_error_code")
    Redis.current.hdel("example/opendata", "last_page")
    Redis.current.hdel("example/opendata", "samples")
    Redis.current.zremrangebyrank("example/opendata/activities", 0, -1)
    Redis.current.zremrangebyrank("example/opendata/boundary", 0, -1)
    WebMock.stub_request(:get, "http://www.example.com").to_return(body: load_fixture("multiple-items.json"))
    WebMock.stub_request(:get, "http://www.example.com/last").to_return(body: load_fixture("last-page.json"))
  end

  describe "#update" do
    it "harvests activities and stores sample size and last page uri" do
      summary.update

      samples = Redis.current.hget(summary.dataset_key, "samples")
      last_page = Redis.current.hget(summary.dataset_key, "last_page")
      ascore = Redis.current.zscore("example/opendata/activities", "body attack")
      bscore = Redis.current.zscore("example/opendata/boundary", "Colchester")

      expect(samples.to_i).to eql(1)
      expect(last_page).to eql("http://www.example.com/last")
      expect(ascore).to eql(1.0)
      expect(bscore).to eql(1.0)
      expect(summary.last_updated.class).to eql(Time)
    end

    it "doesn't increment score once max samples reached" do
      ENV["SUMMARY_SAMPLE_LIMIT"]="0"
      summary.update
      score = Redis.current.zscore("example/opendata/activities", "body attack")
      expect(score).to eql(nil)
      ENV["SUMMARY_SAMPLE_LIMIT"]="500"
    end

    it "records last attempt timestamp and error code when endpoint is down" do
      WebMock.stub_request(:get, "http://www.example.com").to_return(status: 500)
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1506335263)
      summary.update
      expect(summary.last_updated).to eql(nil)
      expect(summary.last_attempt).to eql(Time.at(1506335263))
      expect(summary.error_code).to eql("500")
    end

    it "records last attempt timestamp and error when other problem stops update" do
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1506335263)
      allow(summary).to receive(:harvest).and_raise("boom")
      summary.update
      expect(summary.last_updated).to eql(nil)
      expect(summary.last_attempt).to eql(Time.at(1506335263))
      expect(summary.error_code).to eql("?")
    end
  end

  describe "#last_page" do
    it "returns last page uri" do
      Redis.current.hset(summary.dataset_key, "last_page", "http://www.example.com/last")
      expect(summary.last_page).to eql("http://www.example.com/last")
    end
  end

  describe "#samples" do
    it "returns redis store for dataset activity samples count" do
      Redis.current.hdel(summary.dataset_key, "samples")
      Redis.current.hincrby(summary.dataset_key, "samples", 1)
      expect(summary.samples).to eql(1)
    end
  end

  describe "#restart" do
    it "clears all summary data" do
      Redis.current.hincrby(summary.dataset_key, "samples", 1)
      Redis.current.hset(summary.dataset_key, "last_page", "http://example.com/")
      Redis.current.zincrby("example/opendata/boundary", 1, "My boundary")
      Redis.current.zincrby("example/opendata/activities", 1, "My activity")
      summary.restart
      expect(summary.samples).to eql(0)
      expect(summary.last_page).to eql(nil)
      expect(summary.ranked_boundaries).to eql([])
      expect(summary.ranked_activities).to eql([])
    end
  end

  describe "#restart_from_last_page" do
    it "clears all summary data leaving last page so summary can start from last page" do
      Redis.current.hincrby(summary.dataset_key, "samples", 1)
      Redis.current.hset(summary.dataset_key, "last_page", "http://example.com/")
      Redis.current.zincrby("example/opendata/boundary", 1, "My boundary")
      Redis.current.zincrby("example/opendata/activities", 1, "My activity")
      summary.restart_from_last_page
      expect(summary.samples).to eql(0)
      expect(summary.last_page).to eql("http://example.com/")
      expect(summary.ranked_boundaries).to eql([])
      expect(summary.ranked_activities).to eql([])
    end
  end

  describe "#clear_samples" do
    it "clears sample counts for dataset summary" do
      Redis.current.hincrby(summary.dataset_key, "samples", 1)
      summary.clear_samples
      expect(summary.samples).to eql(0)
    end
  end

  describe "#clear_last_page" do
    it "clears last_page key for dataset summary" do
      Redis.current.hset(summary.dataset_key, "last_page", "http://example.com/")
      summary.clear_last_page
      expect(summary.last_page).to eql(nil)
    end
  end

  describe "#clear_boundaries" do
    it "clears redis store of ranked boundaries" do
      Redis.current.zincrby("example/opendata/boundary", 1, "My boundary")
      summary.clear_boundaries
      expect(summary.ranked_boundaries).to eql([])
    end
  end

  describe "#clear_activities" do
    it "clears redis store of ranked activities" do
      Redis.current.zincrby("example/opendata/activities", 1, "My activity")
      summary.clear_activities
      expect(summary.ranked_activities).to eql([])
    end
  end

  describe "#ranked_activities" do
    it "returns an ordered list of activities" do
      activities = ["C", "A", "B", "A", "B", "A", "A"]
      activities.each { |a| Redis.current.zincrby("example/opendata/activities", 1, a) }
      expect(summary.ranked_activities).to eql(["A", "B", "C"])
      expect(summary.ranked_activities(2)).to eql(["A", "B"])
    end
  end

  describe "#activities" do
    it "returns a hash with zscores for each activity" do
      activities = ["C", "A", "B", "A", "B", "A", "A"]
      activities.each { |a| Redis.current.zincrby("example/opendata/activities", 1, a) }
      expect(summary.activities).to eql({ "C" => 1.0, "B" => 2.0, "A" => 4.0 })
    end
  end

  describe "#boundaries" do
    it "returns an ordered list of boundaries" do
      boundaries = ["C", "A", "B", "A", "B", "A", "A"]
      boundaries.each { |b| Redis.current.zincrby("example/opendata/boundary", 1, b) }
      expect(summary.boundaries).to eql({ "C" => 1.0, "B" => 2.0, "A" => 4.0 })
    end
  end

  describe "#ranked_boundaries" do
    it "returns a hash with zscores for each boundary" do
      boundaries = ["C", "A", "B", "A", "B", "A", "A"]
      boundaries.each { |b| Redis.current.zincrby("example/opendata/boundary", 1, b) }
      expect(summary.ranked_boundaries).to eql(["A", "B", "C"])
      expect(summary.ranked_boundaries(2)).to eql(["A", "B"])
    end
  end

  describe "#normalise_activity" do
    it "strips white space and downcases" do
      expect(summary.normalise_activity(" muh Activity ")).to eql("muh activity")
    end
  end

  describe "#zincr_activities" do
    it "increments sorted set scores for extracted activity names" do
      item = { "data" => { "activity" => ["Body Attack", "Boxing Fitness"] } }
      summary.zincr_activities(item)
      score1 = Redis.current.zscore("example/opendata/activities", "body attack")
      score2 = Redis.current.zscore("example/opendata/activities", "boxing fitness")
      expect(score1).to eql(1.0)
      expect(score2).to eql(1.0)
    end
  end

  describe "#zincr_boundary" do
    it "increments sorted set scores for reverse geocoded boundary name" do
      items = [{ 
          "data" =>{ "location"=> { "geo" => { "latitude" => "51.27262669", "longitude" => "-0.08660358" } } } 
        }, { 
          "data" =>{ "location"=> { "geo" => { "latitude" => 51.27262668, "longitude" => -0.08660357 } } } 
      }]
      items.each {|i| summary.zincr_boundary(i) }  
      score = Redis.current.zscore("example/opendata/boundary", "Tandridge")
      expect(score).to eql(2.0)
    end
  end

end