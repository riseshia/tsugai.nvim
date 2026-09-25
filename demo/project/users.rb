module Users
  def self.fetch_user(id)
    { id: id }
  end

  def self.fetch_users(ids)
    ids.map { |id| fetch_user(id) }
  end
end
