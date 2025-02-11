require_relative './edit_field'

class MultiSelectField < EditField

  def multiselect?
    field_container.has_selector?('.inline-edit--toggle-multiselect .icon-minus2')
  end

  def expect_save_button(enabled: true)
    if enabled
      expect(field_container).to have_no_selector("#{control_link}[disabled]")
    else
      expect(field_container).to have_selector("#{control_link}[disabled]")
    end
  end

  def save!
    submit_by_click
  end

  def field_type
    'create-autocompleter'
  end

  def control_link(action = :save)
    raise 'Invalid link' unless [:save, :cancel].include?(action)
    ".inplace-edit--control--#{action}"
  end
end
