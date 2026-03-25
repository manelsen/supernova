//// Tests for Discord REST API Client

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/adapters/discord_rest as rest

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn new_config_test() {
  let config = rest.new_config("test-token")

  config.bot_token |> should.equal("test-token")
  config.base_url |> should.equal(None)
  config.timeout_ms |> should.equal(30_000)
}

pub fn with_base_url_test() {
  let config =
    rest.new_config("test-token")
    |> rest.with_base_url("https://custom.api.url")

  config.base_url |> should.equal(Some("https://custom.api.url"))
}

pub fn with_timeout_test() {
  let config =
    rest.new_config("test-token")
    |> rest.with_timeout(60_000)

  config.timeout_ms |> should.equal(60_000)
}

// ============================================================================
// Message Options Builder Tests
// ============================================================================

pub fn new_message_options_test() {
  let opts = rest.new_message_options()

  opts.content |> should.equal(None)
  opts.tts |> should.equal(None)
  list.length(opts.embeds) |> should.equal(0)
  list.length(opts.attachments) |> should.equal(0)
  opts.message_reference |> should.equal(None)
}

pub fn with_content_test() {
  let opts =
    rest.new_message_options()
    |> rest.with_content("Hello, Discord!")

  opts.content |> should.equal(Some("Hello, Discord!"))
}

pub fn with_tts_test() {
  let opts =
    rest.new_message_options()
    |> rest.with_tts(True)

  opts.tts |> should.equal(Some(True))
}

pub fn with_embed_test() {
  let embed = rest.new_embed() |> rest.embed_title("Test")
  let opts =
    rest.new_message_options()
    |> rest.with_embed(embed)

  list.length(opts.embeds) |> should.equal(1)
}

pub fn with_embeds_test() {
  let embed1 = rest.new_embed() |> rest.embed_title("First")
  let embed2 = rest.new_embed() |> rest.embed_title("Second")
  let opts =
    rest.new_message_options()
    |> rest.with_embeds([embed1, embed2])

  list.length(opts.embeds) |> should.equal(2)
}

pub fn with_attachment_test() {
  let att = rest.new_attachment("0", "test.png")
  let opts =
    rest.new_message_options()
    |> rest.with_attachment(att)

  list.length(opts.attachments) |> should.equal(1)
}

pub fn with_attachments_test() {
  let att1 = rest.new_attachment("0", "test1.png")
  let att2 = rest.new_attachment("1", "test2.png")
  let opts =
    rest.new_message_options()
    |> rest.with_attachments([att1, att2])

  list.length(opts.attachments) |> should.equal(2)
}

pub fn with_message_reference_test() {
  let ref = rest.reply_to("123456789")
  let opts =
    rest.new_message_options()
    |> rest.with_message_reference(ref)

  case opts.message_reference {
    Some(r) -> r.message_id |> should.equal(Some("123456789"))
    None -> should.fail()
  }
}

pub fn with_allowed_mentions_test() {
  let mentions =
    rest.AllowedMentions(
      parse: ["users"],
      users: ["123"],
      roles: [],
      replied_user: Some(True),
    )
  let opts =
    rest.new_message_options()
    |> rest.with_allowed_mentions(mentions)

  case opts.allowed_mentions {
    Some(m) -> {
      list.length(m.parse) |> should.equal(1)
      m.replied_user |> should.equal(Some(True))
    }
    None -> should.fail()
  }
}

// ============================================================================
// Embed Builder Tests
// ============================================================================

pub fn new_embed_test() {
  let embed = rest.new_embed()

  embed.title |> should.equal(None)
  embed.description |> should.equal(None)
  embed.url |> should.equal(None)
  embed.timestamp |> should.equal(None)
  embed.color |> should.equal(None)
  embed.footer |> should.equal(None)
  embed.image |> should.equal(None)
  embed.thumbnail |> should.equal(None)
  embed.author |> should.equal(None)
  list.length(embed.fields) |> should.equal(0)
}

pub fn embed_title_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_title("My Title")

  embed.title |> should.equal(Some("My Title"))
}

pub fn embed_description_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_description("This is a description")

  embed.description |> should.equal(Some("This is a description"))
}

pub fn embed_url_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_url("https://example.com")

  embed.url |> should.equal(Some("https://example.com"))
}

pub fn embed_timestamp_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_timestamp("2024-01-01T00:00:00Z")

  embed.timestamp |> should.equal(Some("2024-01-01T00:00:00Z"))
}

pub fn embed_color_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_color(0xFF5733)

  embed.color |> should.equal(Some(0xFF5733))
}

pub fn embed_footer_test() {
  let footer = rest.new_footer("Footer text")
  let embed =
    rest.new_embed()
    |> rest.embed_footer(footer)

  case embed.footer {
    Some(f) -> f.text |> should.equal("Footer text")
    None -> should.fail()
  }
}

pub fn embed_image_test() {
  let image = rest.new_image("https://example.com/image.png")
  let embed =
    rest.new_embed()
    |> rest.embed_image(image)

  case embed.image {
    Some(img) -> img.url |> should.equal("https://example.com/image.png")
    None -> should.fail()
  }
}

pub fn embed_thumbnail_test() {
  let thumb = rest.new_thumbnail("https://example.com/thumb.png")
  let embed =
    rest.new_embed()
    |> rest.embed_thumbnail(thumb)

  case embed.thumbnail {
    Some(t) -> t.url |> should.equal("https://example.com/thumb.png")
    None -> should.fail()
  }
}

pub fn embed_author_test() {
  let author = rest.new_author("Author Name")
  let embed =
    rest.new_embed()
    |> rest.embed_author(author)

  case embed.author {
    Some(a) -> a.name |> should.equal("Author Name")
    None -> should.fail()
  }
}

pub fn embed_field_test() {
  let field = rest.new_field("Name", "Value")
  let embed =
    rest.new_embed()
    |> rest.embed_field(field)

  list.length(embed.fields) |> should.equal(1)
  case embed.fields {
    [f] -> {
      f.name |> should.equal("Name")
      f.value |> should.equal("Value")
    }
    _ -> should.fail()
  }
}

pub fn embed_fields_test() {
  let field1 = rest.new_field("Name1", "Value1")
  let field2 = rest.new_field("Name2", "Value2")
  let embed =
    rest.new_embed()
    |> rest.embed_fields([field1, field2])

  list.length(embed.fields) |> should.equal(2)
}

// ============================================================================
// Embed Component Builder Tests
// ============================================================================

pub fn new_footer_test() {
  let footer = rest.new_footer("Footer text")

  footer.text |> should.equal("Footer text")
  footer.icon_url |> should.equal(None)
}

pub fn footer_icon_url_test() {
  let footer =
    rest.new_footer("Footer text")
    |> rest.footer_icon_url("https://example.com/icon.png")

  footer.icon_url |> should.equal(Some("https://example.com/icon.png"))
}

pub fn new_image_test() {
  let image = rest.new_image("https://example.com/image.png")

  image.url |> should.equal("https://example.com/image.png")
}

pub fn new_thumbnail_test() {
  let thumb = rest.new_thumbnail("https://example.com/thumb.png")

  thumb.url |> should.equal("https://example.com/thumb.png")
}

pub fn new_author_test() {
  let author = rest.new_author("Author Name")

  author.name |> should.equal("Author Name")
  author.url |> should.equal(None)
  author.icon_url |> should.equal(None)
}

pub fn author_url_test() {
  let author =
    rest.new_author("Author Name")
    |> rest.author_url("https://example.com")

  author.url |> should.equal(Some("https://example.com"))
}

pub fn author_icon_url_test() {
  let author =
    rest.new_author("Author Name")
    |> rest.author_icon_url("https://example.com/icon.png")

  author.icon_url |> should.equal(Some("https://example.com/icon.png"))
}

pub fn new_field_test() {
  let field = rest.new_field("Name", "Value")

  field.name |> should.equal("Name")
  field.value |> should.equal("Value")
  field.inline |> should.equal(None)
}

pub fn field_inline_test() {
  let field =
    rest.new_field("Name", "Value")
    |> rest.field_inline(True)

  field.inline |> should.equal(Some(True))
}

// ============================================================================
// Attachment Builder Tests
// ============================================================================

pub fn new_attachment_test() {
  let att = rest.new_attachment("0", "test.png")

  att.id |> should.equal("0")
  att.filename |> should.equal("test.png")
  att.description |> should.equal(None)
}

pub fn attachment_description_test() {
  let att =
    rest.new_attachment("0", "test.png")
    |> rest.attachment_description("A test image")

  att.description |> should.equal(Some("A test image"))
}

// ============================================================================
// Message Reference Builder Tests
// ============================================================================

pub fn reply_to_test() {
  let ref = rest.reply_to("123456789")

  ref.message_id |> should.equal(Some("123456789"))
  ref.channel_id |> should.equal(None)
  ref.guild_id |> should.equal(None)
}

pub fn reply_to_in_channel_test() {
  let ref = rest.reply_to_in_channel("123456789", "987654321")

  ref.message_id |> should.equal(Some("123456789"))
  ref.channel_id |> should.equal(Some("987654321"))
  ref.guild_id |> should.equal(None)
}

// ============================================================================
// Client Lifecycle Tests
// ============================================================================

pub fn start_client_test() {
  let config = rest.new_config("test-token")
  let result = rest.start(config)

  case result {
    Ok(client) -> {
      // Client should be a valid actor subject
      let rate_limits = rest.get_rate_limit_info(client)
      rate_limits |> should.equal(dict.new())

      // Clean up
      rest.clear_rate_limits(client)
    }
    Error(_) -> should.fail()
  }
}

pub fn clear_rate_limits_test() {
  let config = rest.new_config("test-token")
  let assert Ok(client) = rest.start(config)

  rest.clear_rate_limits(client)

  let rate_limits = rest.get_rate_limit_info(client)
  rate_limits |> should.equal(dict.new())
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn http_error_test() {
  let error = rest.HttpError(message: "Connection failed")

  case error {
    rest.HttpError(msg) -> msg |> should.equal("Connection failed")
  }
}

pub fn rate_limited_error_test() {
  let error = rest.RateLimited(retry_after_ms: 5000)

  case error {
    rest.RateLimited(ms) -> ms |> should.equal(5000)
  }
}

pub fn bad_request_error_test() {
  let error = rest.BadRequest(message: "Invalid request")

  case error {
    rest.BadRequest(msg) -> msg |> should.equal("Invalid request")
  }
}

pub fn unauthorized_error_test() {
  let error = rest.Unauthorized

  case error {
    rest.Unauthorized -> should.equal(True, True)
  }
}

pub fn forbidden_error_test() {
  let error = rest.Forbidden(message: "Missing permissions")

  case error {
    rest.Forbidden(msg) -> msg |> should.equal("Missing permissions")
  }
}

pub fn not_found_error_test() {
  let error = rest.NotFound(message: "Channel not found")

  case error {
    rest.NotFound(msg) -> msg |> should.equal("Channel not found")
  }
}

pub fn internal_error_test() {
  let error = rest.InternalError(message: "Discord API error")

  case error {
    rest.InternalError(msg) -> msg |> should.equal("Discord API error")
  }
}

pub fn unknown_error_test() {
  let error = rest.UnknownError(status: 418, body: "I'm a teapot")

  case error {
    rest.UnknownError(status, body) -> {
      status |> should.equal(418)
      body |> should.equal("I'm a teapot")
    }
  }
}

pub fn json_error_test() {
  let error = rest.JsonError(message: "Failed to parse")

  case error {
    rest.JsonError(msg) -> msg |> should.equal("Failed to parse")
  }
}

// ============================================================================
// Rate Limit Info Tests
// ============================================================================

pub fn rate_limit_info_test() {
  let info =
    rest.RateLimitInfo(
      limit: 10,
      remaining: 5,
      reset_after_ms: 1000,
      bucket: Some("abc123"),
      global: False,
    )

  info.limit |> should.equal(10)
  info.remaining |> should.equal(5)
  info.reset_after_ms |> should.equal(1000)
  info.bucket |> should.equal(Some("abc123"))
  info.global |> should.equal(False)
}

// ============================================================================
// Sent Message Tests
// ============================================================================

pub fn sent_message_test() {
  let msg =
    rest.SentMessage(
      id: "123456789",
      channel_id: "987654321",
      guild_id: Some("111222333"),
      content: "Hello!",
      timestamp: "2024-01-01T00:00:00Z",
    )

  msg.id |> should.equal("123456789")
  msg.channel_id |> should.equal("987654321")
  msg.guild_id |> should.equal(Some("111222333"))
  msg.content |> should.equal("Hello!")
}

// ============================================================================
// Complex Embed Test
// ============================================================================

pub fn complex_embed_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_title("Complex Embed")
    |> rest.embed_description("A full featured embed")
    |> rest.embed_color(0x00FF00)
    |> rest.embed_footer(
      rest.new_footer("Footer")
      |> rest.footer_icon_url("https://example.com/footer.png"),
    )
    |> rest.embed_image(rest.new_image("https://example.com/image.png"))
    |> rest.embed_thumbnail(rest.new_thumbnail("https://example.com/thumb.png"))
    |> rest.embed_author(
      rest.new_author("Author")
      |> rest.author_url("https://example.com")
      |> rest.author_icon_url("https://example.com/author.png"),
    )
    |> rest.embed_field(
      rest.new_field("Field 1", "Value 1")
      |> rest.field_inline(True),
    )
    |> rest.embed_field(
      rest.new_field("Field 2", "Value 2")
      |> rest.field_inline(True),
    )

  embed.title |> should.equal(Some("Complex Embed"))
  embed.description |> should.equal(Some("A full featured embed"))
  embed.color |> should.equal(Some(0x00FF00))
  list.length(embed.fields) |> should.equal(2)
}

// ============================================================================
// Complex Message Options Test
// ============================================================================

pub fn complex_message_options_test() {
  let embed =
    rest.new_embed()
    |> rest.embed_title("Test")
    |> rest.embed_color(0xFF0000)

  let attachment =
    rest.new_attachment("0", "image.png")
    |> rest.attachment_description("An image")

  let opts =
    rest.new_message_options()
    |> rest.with_content("Check this out!")
    |> rest.with_embed(embed)
    |> rest.with_attachment(attachment)
    |> rest.with_message_reference(rest.reply_to("123456789"))

  opts.content |> should.equal(Some("Check this out!"))
  list.length(opts.embeds) |> should.equal(1)
  list.length(opts.attachments) |> should.equal(1)
}

// ============================================================================
// Allowed Mentions Test
// ============================================================================

pub fn allowed_mentions_test() {
  let mentions =
    rest.AllowedMentions(
      parse: ["users", "roles"],
      users: ["111", "222"],
      roles: ["333"],
      replied_user: Some(True),
    )

  list.length(mentions.parse) |> should.equal(2)
  list.length(mentions.users) |> should.equal(2)
  list.length(mentions.roles) |> should.equal(1)
  mentions.replied_user |> should.equal(Some(True))
}

// ============================================================================
// Bucket State Test
// ============================================================================

pub fn bucket_state_test() {
  let state =
    rest.BucketState(remaining: 5, reset_at: 1000, bucket: Some("bucket123"))

  state.remaining |> should.equal(5)
  state.reset_at |> should.equal(1000)
  state.bucket |> should.equal(Some("bucket123"))
}

// ============================================================================
// API Base URL Test
// ============================================================================

pub fn api_base_url_test() {
  rest.api_base_url |> should.equal("https://discord.com/api/v10")
}

// ============================================================================
// Snowflake Type Test
// ============================================================================

pub fn snowflake_type_test() {
  // Snowflake is just a type alias for String
  let snowflake: rest.Snowflake = "123456789012345678"
  snowflake |> should.equal("123456789012345678")
}
