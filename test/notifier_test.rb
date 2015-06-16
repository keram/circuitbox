require 'test_helper'
require 'circuitbox/notifier'
require 'active_support/notifications'

describe Circuitbox::Notifier do
  subject { Circuitbox::Notifier.new(:yammer, 12) }

  it "[notify] sends an ActiveSupport::Notification" do
    ActiveSupport::Notifications.expects(:instrument)
      .with("circuit_open", circuit: 'yammer:12')
    subject.notify(:open)
  end

  it "[notify_warning] sends an ActiveSupport::Notification" do
    ActiveSupport::Notifications.expects(:instrument)
      .with("circuit_warning", { circuit: 'yammer:12', message: 'hello' })
    subject.notify_warning('hello')
  end

  it '[gauge] sends an ActiveSupport::Notifier' do
    ActiveSupport::Notifications.expects(:instrument)
      .with("circuit_gauge", { circuit: 'yammer:12', gauge: 'ratio', value: 12 })
    subject.metric_gauge(:ratio, 12)
  end
end
