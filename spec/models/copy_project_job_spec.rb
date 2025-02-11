#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2018 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2017 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See docs/COPYRIGHT.rdoc for more details.
#++

require 'spec_helper'

describe CopyProjectJob, type: :model do
  let(:project) { FactoryBot.create(:project, public: false) }
  let(:user) { FactoryBot.create(:user) }
  let(:role) { FactoryBot.create(:role, permissions: [:copy_projects]) }
  let(:params) { { name: 'Copy', identifier: 'copy' } }
  let(:maildouble) { double('Mail::Message', deliver: true) }

  before do
    allow(maildouble).to receive(:deliver_now).and_return nil
  end

  describe 'copy localizes error message' do
    let(:user_de) { FactoryBot.create(:admin, language: :de) }
    let(:source_project) { FactoryBot.create(:project) }
    let(:target_project) { FactoryBot.create(:project) }

    let(:copy_job) do
      CopyProjectJob.new user_id: user_de.id,
                         source_project_id: source_project.id,
                         target_project_params: {},
                         associations_to_copy: []
    end

    before do
      # 'Delayed Job' uses a work around to get Rails 3 mailers working with it
      # (see https://github.com/collectiveidea/delayed_job#rails-3-mailers).
      # Thus, we need to return a message object here, otherwise 'Delayed Job'
      # will complain about an object without a method #deliver.
      allow(ProjectMailer).to receive(:copy_project_failed).and_return(maildouble)
    end

    it 'sets locale correctly' do
      expect(copy_job).to receive(:create_project_copy) do |*_args|
        expect(I18n.locale).to eq(:de)
        [nil, nil]
      end

      copy_job.perform
    end
  end

  describe 'copy project succeeds with errors' do
    let(:admin) { FactoryBot.create(:admin) }
    let(:source_project) { FactoryBot.create(:project, types: [type]) }
    let!(:work_package) { FactoryBot.create(:work_package, project: source_project, type: type) }
    let(:type) { FactoryBot.create(:type_bug) }
    let(:custom_field) do
      FactoryBot.create(:work_package_custom_field,
                        name: 'required_field',
                        field_format: 'text',
                        is_required: true,
                        is_for_all: true)
    end
    let(:copy_job) do
      CopyProjectJob.new user_id: admin.id,
                         source_project_id: source_project.id,
                         target_project_params: params,
                         associations_to_copy: [:work_packages]
    end # send mails
    let(:params) { { name: 'Copy', identifier: 'copy', type_ids: [type.id], work_package_custom_field_ids: [custom_field.id] } }
    let(:expected_error_message) { "#{WorkPackage.model_name.human} '#{work_package.type.name} #: #{work_package.subject}': #{custom_field.name} #{I18n.t('errors.messages.blank')}." }

    before do
      source_project.work_package_custom_fields << custom_field
      type.custom_fields << custom_field

      allow(User).to receive(:current).and_return(admin)

      # 'Delayed Job' uses a work around to get Rails 3 mailers working with it
      # (see https://github.com/collectiveidea/delayed_job#rails-3-mailers).
      # Thus, we need to return a message object here, otherwise 'Delayed Job'
      # will complain about an object without a method #deliver.
      allow(ProjectMailer).to receive(:copy_project_succeeded).and_return(maildouble)

      @copied_project, @errors = copy_job.send(:create_project_copy,
                                               source_project,
                                               params,
                                               [:work_packages], # associations
                                               false)
    end

    it 'copies the project' do
      expect(Project.find_by(identifier: params[:identifier])).to eq(@copied_project)
    end

    it 'sets descriptive validation errors' do
      expect(@errors.first).to eq(expected_error_message)
    end
  end

  describe 'project has an invalid repository' do
    let(:admin) { FactoryBot.create(:admin) }
    let(:source_project) do
      project = FactoryBot.create(:project)

      # add invalid repo
      repository = Repository::Git.new scm_type: :existing, project: project
      repository.save!(validate: false)
      project.reload
      project
    end

    let(:copy_job) {
      CopyProjectJob.new user_id: admin.id,
                         source_project_id: source_project.id,
                         target_project_params: params,
                         associations_to_copy: [:work_packages]
    } # send mails
    let(:params) { { name: 'Copy', identifier: 'copy' } }

    before do
      allow(User).to receive(:current).and_return(admin)
    end

    it 'saves without the repository' do
      expect(source_project).not_to be_valid

      copied_project, errors = copy_job.send(:create_project_copy,
                                             source_project,
                                             params,
                                             [:work_packages], # associations
                                             false)

      expect(errors).to be_empty
      expect(copied_project).to be_valid
      expect(copied_project.repository).to be_nil
      expect(copied_project.enabled_module_names).not_to include 'repository'
    end
  end

  describe 'copy project fails with internal error' do
    let(:admin) { FactoryBot.create(:admin) }
    let(:source_project) { FactoryBot.create(:project) }
    let(:copy_job) do
      CopyProjectJob.new user_id: admin.id,
                         source_project_id: source_project.id,
                         target_project_params: params,
                         associations_to_copy: [:work_packages]
    end # send mails
    let(:params) { { name: 'Copy', identifier: 'copy' } }

    before do
      allow(User).to receive(:current).and_return(admin)
      allow(ProjectMailer).to receive(:copy_project_succeeded).and_raise 'error message not meant for user'
    end

    it 'renders a error when unexpected errors occur' do
      expect(ProjectMailer)
        .to receive(:copy_project_failed)
        .with(admin, source_project, 'Copy', [I18n.t('copy_project.failed_internal')])
        .and_return maildouble

      expect { copy_job.perform }.not_to raise_error
    end
  end

  shared_context 'copy project' do
    before do
      copy_project_job = CopyProjectJob.new(user_id: user.id,
                                            source_project_id: project_to_copy.id,
                                            target_project_params: params,
                                            associations_to_copy: [:members])
      copy_project_job.perform
    end
  end

  describe 'perform' do
    before do
      login_as(user)
      expect(User).to receive(:current=).with(user)
    end

    describe 'subproject' do
      let(:params) { { name: 'Copy', identifier: 'copy', parent_id: project.id } }
      let(:subproject) { FactoryBot.create(:project, parent: project) }

      describe 'invalid parent' do
        include_context 'copy project' do
          let(:project_to_copy) { subproject }
        end

        it "creates no new project" do
          expect(Project.all).to match_array([project, subproject])
        end

        it "notifies the user of the failure" do
          mail = ActionMailer::Base.deliveries
            .find { |m| m.message_id.start_with? "openproject.project-#{user.id}-#{subproject.id}" }

          expect(mail).to be_present
          expect(mail.subject).to eq "Cannot copy project #{subproject.name}"
        end
      end

      describe 'valid parent' do
        let(:role_add_subproject) { FactoryBot.create(:role, permissions: [:add_subprojects]) }
        let(:member_add_subproject) do
          FactoryBot.create(:member,
                            user: user,
                            project: project,
                            roles: [role_add_subproject])
        end

        before do
          member_add_subproject
        end

        include_context 'copy project' do
          let(:project_to_copy) { subproject }
        end

        subject { Project.find_by(identifier: 'copy') }

        it 'copies the project' do
          expect(subject).not_to be_nil
          expect(subject.parent).to eql(project)

          expect(subproject.reload.enabled_module_names).not_to be_empty
        end

        it "notifies the user of the success" do
          mail = ActionMailer::Base.deliveries
            .find { |m| m.message_id.start_with? "openproject.project-#{user.id}-#{subject.id}" }

          expect(mail).to be_present
          expect(mail.subject).to eq "Created project #{subject.name}"
        end
      end
    end
  end
end
