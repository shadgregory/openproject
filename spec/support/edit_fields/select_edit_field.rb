require_relative './edit_field'

class SelectField < EditField
  def input_selector
    super + ' .ng-value-label'
  end

  def expect_value(value)
    expect(input_element.text).to eq(value)
  end

  def field_type
    'create-autocompleter'
  end
end
