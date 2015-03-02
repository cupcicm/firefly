class CreateUserColumn < ActiveRecord::Migration
  def change
    add_column :urls, :user, :string, default: 'default user'
    add_index :urls, :user
  end
end
