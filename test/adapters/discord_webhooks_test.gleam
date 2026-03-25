import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/adapters/discord_webhooks as webhooks

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn new_config_creates_default_config() {
  let config = webhooks.new_config("test-token")
  config.bot_token |> should.equal("test-token")
  config.base_url |> should.equal(None)
  config.timeout_ms |> should.equal(30_000)
}

pub fn with_base_url_sets_custom_url() {
  let config =
    webhooks.new_config("test-token")
    |> webhooks.with_base_url("https://custom.api.url")

  config.base_url |> should.equal(Some("https://custom.api.url"))
}

pub fn with_timeout_sets_custom_timeout() {
  let config =
    webhooks.new_config("test-token")
    |> webhooks.with_timeout(60_000)

  config.timeout_ms |> should.equal(60_000)
}

// ============================================================================
// Create Webhook Options Builder Tests
// ============================================================================

pub fn new_create_webhook_options_creates_options() {
  let opts = webhooks.new_create_webhook_options("My Webhook")
  opts.name |> should.equal("My Webhook")
  opts.avatar |> should.equal(None)
}

pub fn with_webhook_avatar_sets_avatar() {
  let opts =
    webhooks.new_create_webhook_options("My Webhook")
    |> webhooks.with_webhook_avatar("data:image/png;base64,abc123")

  opts.avatar |> should.equal(Some("data:image/png;base64,abc123"))
}

// ============================================================================
// Modify Webhook Options Builder Tests
// ============================================================================

pub fn new_modify_webhook_options_creates_empty_options() {
  let opts = webhooks.new_modify_webhook_options()
  opts.name |> should.equal(None)
  opts.avatar |> should.equal(None)
  opts.channel_id |> should.equal(None)
}

pub fn modify_webhook_name_sets_name() {
  let opts =
    webhooks.new_modify_webhook_options()
    |> webhooks.modify_webhook_name("New Name")

  opts.name |> should.equal(Some("New Name"))
}

pub fn modify_webhook_avatar_sets_avatar() {
  let opts =
    webhooks.new_modify_webhook_options()
    |> webhooks.modify_webhook_avatar("data:image/png;base64,abc123")

  opts.avatar |> should.equal(Some("data:image/png;base64,abc123"))
}

pub fn modify_webhook_channel_sets_channel() {
  let opts =
    webhooks.new_modify_webhook_options()
    |> webhooks.modify_webhook_channel("123456789")

  opts.channel_id |> should.equal(Some("123456789"))
}

// ============================================================================
// Execute Webhook Options Builder Tests
// ============================================================================

pub fn new_execute_webhook_options_creates_empty_options() {
  let opts = webhooks.new_execute_webhook_options()
  opts.content |> should.equal(None)
  opts.username |> should.equal(None)
  opts.avatar_url |> should.equal(None)
  opts.tts |> should.equal(None)
  opts.embeds |> should.equal([])
  opts.allowed_mentions |> should.equal(None)
  opts.thread_id |> should.equal(None)
  opts.wait |> should.equal(None)
}

pub fn with_content_sets_content() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_content("Hello, World!")

  opts.content |> should.equal(Some("Hello, World!"))
}

pub fn with_username_sets_custom_username() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_username("Custom Bot")

  opts.username |> should.equal(Some("Custom Bot"))
}

pub fn with_avatar_url_sets_custom_avatar() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_avatar_url("https://example.com/avatar.png")

  opts.avatar_url |> should.equal(Some("https://example.com/avatar.png"))
}

pub fn with_tts_sets_tts_flag() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_tts(True)

  opts.tts |> should.equal(Some(True))
}

pub fn with_thread_id_sets_thread() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_thread_id("987654321")

  opts.thread_id |> should.equal(Some("987654321"))
}

pub fn with_wait_sets_wait_flag() {
  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_wait(True)

  opts.wait |> should.equal(Some(True))
}

pub fn with_embed_adds_embed() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_title("Test Embed")

  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_embed(embed)

  opts.embeds |> list.length |> should.equal(1)
}

pub fn with_embeds_adds_multiple_embeds() {
  let embed1 = webhooks.new_embed() |> webhooks.embed_title("Embed 1")
  let embed2 = webhooks.new_embed() |> webhooks.embed_title("Embed 2")

  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_embeds([embed1, embed2])

  opts.embeds |> list.length |> should.equal(2)
}

pub fn with_allowed_mentions_sets_mentions() {
  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_parse("users")

  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_allowed_mentions(mentions)

  case opts.allowed_mentions {
    Some(m) -> m.parse |> list.length |> should.equal(1)
    None -> should.fail()
  }
}

// ============================================================================
// Edit Webhook Message Options Builder Tests
// ============================================================================

pub fn new_edit_webhook_message_options_creates_empty_options() {
  let opts = webhooks.new_edit_webhook_message_options()
  opts.content |> should.equal(None)
  opts.embeds |> should.equal([])
  opts.allowed_mentions |> should.equal(None)
}

pub fn edit_with_content_sets_content() {
  let opts =
    webhooks.new_edit_webhook_message_options()
    |> webhooks.edit_with_content("Updated content")

  opts.content |> should.equal(Some("Updated content"))
}

pub fn edit_with_embed_adds_embed() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_title("Updated Embed")

  let opts =
    webhooks.new_edit_webhook_message_options()
    |> webhooks.edit_with_embed(embed)

  opts.embeds |> list.length |> should.equal(1)
}

// ============================================================================
// Embed Builder Tests
// ============================================================================

pub fn new_embed_creates_empty_embed() {
  let embed = webhooks.new_embed()
  embed.title |> should.equal(None)
  embed.description |> should.equal(None)
  embed.url |> should.equal(None)
  embed.timestamp |> should.equal(None)
  embed.color |> should.equal(None)
  embed.footer |> should.equal(None)
  embed.image |> should.equal(None)
  embed.thumbnail |> should.equal(None)
  embed.author |> should.equal(None)
  embed.fields |> should.equal([])
}

pub fn embed_title_sets_title() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_title("Embed Title")

  embed.title |> should.equal(Some("Embed Title"))
}

pub fn embed_description_sets_description() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_description("This is an embed description")

  embed.description |> should.equal(Some("This is an embed description"))
}

pub fn embed_url_sets_url() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_url("https://example.com")

  embed.url |> should.equal(Some("https://example.com"))
}

pub fn embed_timestamp_sets_timestamp() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_timestamp("2024-01-01T00:00:00.000Z")

  embed.timestamp |> should.equal(Some("2024-01-01T00:00:00.000Z"))
}

pub fn embed_color_sets_color() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_color(0xFF5733)

  embed.color |> should.equal(Some(0xFF5733))
}

pub fn embed_footer_sets_footer() {
  let footer = webhooks.new_footer("Footer text")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_footer(footer)

  case embed.footer {
    Some(f) -> f.text |> should.equal("Footer text")
    None -> should.fail()
  }
}

pub fn embed_image_sets_image() {
  let image = webhooks.new_image("https://example.com/image.png")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_image(image)

  case embed.image {
    Some(img) -> img.url |> should.equal("https://example.com/image.png")
    None -> should.fail()
  }
}

pub fn embed_thumbnail_sets_thumbnail() {
  let thumbnail = webhooks.new_thumbnail("https://example.com/thumb.png")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_thumbnail(thumbnail)

  case embed.thumbnail {
    Some(t) -> t.url |> should.equal("https://example.com/thumb.png")
    None -> should.fail()
  }
}

pub fn embed_author_sets_author() {
  let author = webhooks.new_author("Author Name")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_author(author)

  case embed.author {
    Some(a) -> a.name |> should.equal("Author Name")
    None -> should.fail()
  }
}

pub fn embed_field_adds_field() {
  let field = webhooks.new_field("Field Name", "Field Value")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_field(field)

  embed.fields |> list.length |> should.equal(1)
}

pub fn embed_fields_adds_multiple_fields() {
  let field1 = webhooks.new_field("Field 1", "Value 1")
  let field2 = webhooks.new_field("Field 2", "Value 2")

  let embed =
    webhooks.new_embed()
    |> webhooks.embed_fields([field1, field2])

  embed.fields |> list.length |> should.equal(2)
}

// ============================================================================
// Embed Component Builder Tests
// ============================================================================

pub fn new_footer_creates_footer() {
  let footer = webhooks.new_footer("Footer text")
  footer.text |> should.equal("Footer text")
  footer.icon_url |> should.equal(None)
}

pub fn footer_icon_url_sets_icon() {
  let footer =
    webhooks.new_footer("Footer text")
    |> webhooks.footer_icon_url("https://example.com/icon.png")

  footer.icon_url |> should.equal(Some("https://example.com/icon.png"))
}

pub fn new_image_creates_image() {
  let image = webhooks.new_image("https://example.com/image.png")
  image.url |> should.equal("https://example.com/image.png")
}

pub fn new_thumbnail_creates_thumbnail() {
  let thumbnail = webhooks.new_thumbnail("https://example.com/thumb.png")
  thumbnail.url |> should.equal("https://example.com/thumb.png")
}

pub fn new_author_creates_author() {
  let author = webhooks.new_author("Author Name")
  author.name |> should.equal("Author Name")
  author.url |> should.equal(None)
  author.icon_url |> should.equal(None)
}

pub fn author_url_sets_url() {
  let author =
    webhooks.new_author("Author Name")
    |> webhooks.author_url("https://example.com")

  author.url |> should.equal(Some("https://example.com"))
}

pub fn author_icon_url_sets_icon() {
  let author =
    webhooks.new_author("Author Name")
    |> webhooks.author_icon_url("https://example.com/icon.png")

  author.icon_url |> should.equal(Some("https://example.com/icon.png"))
}

pub fn new_field_creates_field() {
  let field = webhooks.new_field("Name", "Value")
  field.name |> should.equal("Name")
  field.value |> should.equal("Value")
  field.inline |> should.equal(None)
}

pub fn field_inline_sets_inline() {
  let field =
    webhooks.new_field("Name", "Value")
    |> webhooks.field_inline(True)

  field.inline |> should.equal(Some(True))
}

// ============================================================================
// Allowed Mentions Builder Tests
// ============================================================================

pub fn new_allowed_mentions_creates_empty_mentions() {
  let mentions = webhooks.new_allowed_mentions()
  mentions.parse |> should.equal([])
  mentions.users |> should.equal([])
  mentions.roles |> should.equal([])
  mentions.replied_user |> should.equal(None)
}

pub fn allow_parse_adds_parse_type() {
  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_parse("users")
    |> webhooks.allow_parse("roles")

  mentions.parse |> list.length |> should.equal(2)
}

pub fn allow_user_adds_user_id() {
  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_user("123456789")
    |> webhooks.allow_user("987654321")

  mentions.users |> list.length |> should.equal(2)
}

pub fn allow_role_adds_role_id() {
  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_role("111111111")
    |> webhooks.allow_role("222222222")

  mentions.roles |> list.length |> should.equal(2)
}

pub fn allow_replied_user_sets_flag() {
  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_replied_user(True)

  mentions.replied_user |> should.equal(Some(True))
}

// ============================================================================
// Webhook Type Tests
// ============================================================================

pub fn webhook_types_exist() {
  // Just ensure types compile
  let _incoming = webhooks.Incoming
  let _follower = webhooks.ChannelFollower
  let _application = webhooks.Application
  should.equal(True, True)
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn error_types_exist() {
  // Just ensure error types compile
  let _http_error = webhooks.HttpError("test")
  let _rate_limited = webhooks.RateLimited(1000)
  let _bad_request = webhooks.BadRequest("test")
  let _unauthorized = webhooks.Unauthorized
  let _forbidden = webhooks.Forbidden("test")
  let _not_found = webhooks.NotFound("test")
  let _internal_error = webhooks.InternalError("test")
  let _unknown_error = webhooks.UnknownError(500, "body")
  let _json_error = webhooks.JsonError("test")
  let _invalid_token = webhooks.InvalidToken
  let _webhook_not_found = webhooks.WebhookNotFound
  should.equal(True, True)
}

// ============================================================================
// Complex Builder Tests
// ============================================================================

pub fn complex_webhook_message_building() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_title("Notification")
    |> webhooks.embed_description("Something happened!")
    |> webhooks.embed_color(0x00FF00)
    |> webhooks.embed_field(
      webhooks.new_field("Status", "Success") |> webhooks.field_inline(True),
    )
    |> webhooks.embed_footer(
      webhooks.new_footer("Sent at 12:00")
      |> webhooks.footer_icon_url("https://example.com/icon.png"),
    )
    |> webhooks.embed_author(
      webhooks.new_author("System")
      |> webhooks.author_url("https://example.com")
      |> webhooks.author_icon_url("https://example.com/avatar.png"),
    )

  let mentions =
    webhooks.new_allowed_mentions()
    |> webhooks.allow_parse("users")
    |> webhooks.allow_user("123456789")

  let opts =
    webhooks.new_execute_webhook_options()
    |> webhooks.with_content("Webhook message content")
    |> webhooks.with_username("Custom Bot Name")
    |> webhooks.with_avatar_url("https://example.com/bot-avatar.png")
    |> webhooks.with_embed(embed)
    |> webhooks.with_allowed_mentions(mentions)
    |> webhooks.with_thread_id("987654321")
    |> webhooks.with_wait(True)

  // Verify all options are set
  opts.content |> should.equal(Some("Webhook message content"))
  opts.username |> should.equal(Some("Custom Bot Name"))
  opts.avatar_url |> should.equal(Some("https://example.com/bot-avatar.png"))
  opts.embeds |> list.length |> should.equal(1)
  opts.thread_id |> should.equal(Some("987654321"))
  opts.wait |> should.equal(Some(True))
}

pub fn complex_embed_building() {
  let embed =
    webhooks.new_embed()
    |> webhooks.embed_title("Complex Embed")
    |> webhooks.embed_description("A complex embed with all fields")
    |> webhooks.embed_url("https://example.com/embed")
    |> webhooks.embed_timestamp("2024-01-01T00:00:00.000Z")
    |> webhooks.embed_color(0xFF0000)
    |> webhooks.embed_image(webhooks.new_image("https://example.com/image.png"))
    |> webhooks.embed_thumbnail(webhooks.new_thumbnail(
      "https://example.com/thumb.png",
    ))
    |> webhooks.embed_fields([
      webhooks.new_field("Field 1", "Value 1") |> webhooks.field_inline(True),
      webhooks.new_field("Field 2", "Value 2") |> webhooks.field_inline(True),
      webhooks.new_field("Field 3", "Value 3"),
    ])

  // Verify embed has all components
  embed.title |> should.equal(Some("Complex Embed"))
  embed.description |> should.equal(Some("A complex embed with all fields"))
  embed.url |> should.equal(Some("https://example.com/embed"))
  embed.timestamp |> should.equal(Some("2024-01-01T00:00:00.000Z"))
  embed.color |> should.equal(Some(0xFF0000))
  embed.fields |> list.length |> should.equal(3)
}
