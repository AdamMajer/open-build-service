RSpec.describe NotificationActionBarComponent, type: :component do
  context 'for unread notifications' do
    before do
      User.session = create(:user)
      render_inline(described_class.new(state: 'unread', update_path: 'my/notifications', show_read_all_button: true))
    end

    it do
      expect(rendered_content).to have_text("Mark all as 'Read'")
    end

    it do
      expect(rendered_content).to have_link(href: 'my/notifications?update_all=true')
    end

    it do
      expect(rendered_content).to have_text("Mark selected as 'Read'")
    end

    it do
      expect(rendered_content).to have_text('Select All')
    end
  end

  context 'for read notifications' do
    before do
      User.session = create(:user)
      render_inline(described_class.new(state: 'read', update_path: 'my/notifications?state=read', show_read_all_button: true))
    end

    it do
      expect(rendered_content).to have_text("Mark all as 'Unread'")
    end

    it do
      expect(rendered_content).to have_link(href: 'my/notifications?state=read&update_all=true')
    end

    it do
      expect(rendered_content).to have_text("Mark selected as 'Unread'")
    end

    it do
      expect(rendered_content).to have_text('Select All')
    end
  end
end
