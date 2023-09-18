# Report class flags abusive content, be it projects, packages, users or comments
class Report < ApplicationRecord
  validates :reason, length: { maximum: 65_535 }
  validates :reportable_type, length: { maximum: 255 }

  belongs_to :user, optional: false
  belongs_to :reportable, polymorphic: true, optional: true

  belongs_to :decision, optional: true

  after_create :create_event

  private

  def create_event
    Event::CreateReport.create(event_parameters)
  end

  def event_parameters
    { id: id, user_id: user_id, reportable_id: reportable_id, reportable_type: reportable_type, reason: reason }
  end
end

# == Schema Information
#
# Table name: reports
#
#  id              :bigint           not null, primary key
#  reason          :text(65535)
#  reportable_type :string(255)      indexed => [reportable_id]
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  decision_id     :bigint           indexed
#  reportable_id   :integer          indexed => [reportable_type]
#  user_id         :integer          not null, indexed
#
# Indexes
#
#  index_reports_on_decision_id  (decision_id)
#  index_reports_on_reportable   (reportable_type,reportable_id)
#  index_reports_on_user_id      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (decision_id => decisions.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id)
#
