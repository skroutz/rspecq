# ActiveSupport::Notifications.subscribe %r{.rspec.rspecq} do |*args|
ActiveSupport::Notifications.subscribe "failure.rspec.rspecq" do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  puts "FRAGOU #{event.payload[:notification].example.location_rerun_argument}"
end
