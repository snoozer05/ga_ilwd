# -*- coding: utf-8 -*-

require 'MeCab'

class GA_ILWD
  class Eliza
    def respond(string)
      # TODO
      'わかりません。'
    end
  end

  def initialize
    @tagger = MeCab::Tagger.new
    @eliza = Eliza.new
    # TODO
    # @tuple_space = DRbObject.new_with_uri()
    @last_response_id = nil
    @this_response_id = nil
  end

  def respond(string)
    initialize_state!
    parse_to_node(string)
    while next_node?
      if end_of_sentence?
        finalize!
        break
      end
      set_new_pos
      if chunkable?
        update
      else
        concat
      end
    end
    variable_match
    broad_match
    exact_match
    learn_from_user
    if @last_response_id
      learn_from_user
    end
    # 65％以上合致の内容語列が
    # - あればGA-IL応答出力
    # - なければEliza
    # 応答文生成U->Sルールに保存
  end

  private
  def learn_from_user
    learn(@last_response_id, @exact_content_id)
  end

  def learn_from_self
    learn(@exact_content_id, @this_response_id)
  end

  def learn(request_id, response_id)
    # @tuple_space.write([:learn, request_id, response_id])
  end

  def variable_match
  end

  def retrieve_variable_responses(content)
    single_pattern =
      ContentPattern.where(
        count: 1,
        word: content[:word],
        pos: content[:pos],
        type: content[:conj_type]).first
    return [] if single_pattern.nil?
    ContentRule.where(request_id: single_pattern.pattern_id).all.map{|rule|
      ContentPattern.where(pattern_id: rule.response_id).first
    }.select{|pattern|
      pattern.count == 1
    }
  end

  def broad_match
    content_patterns = []
    @contents.each do |content|
      content_patterns.concat
        ContentPattern.where(
          count: range_of_count,
          word: content[:word],
          pos: content[:pos],
          conj_type: content[:conj_type]).all
    end
    id_to_count = content_patterns.inject({}) do |hash, pattern|
      unless hash.key?(pattern.pattern_id)
        hash[pattern.pattern_id] = pattern.count
      end
      hash
    end
    content_pattern_ids << content_patterns.map{|pattern| pattern.pattern_id}
    id_to_matched = content_pattern_ids.uniq.inject({}) do |hash, id|
      hash[id] = content_pattern_ids.grep(id).size
      hash
    end
    @broad_content_ids = id_to_count.keys.select do |id|
      count = @contents.size > id_to_count[id] ?
        @contents.size : id_to_count[id]
      id_to_matched[id] / count.to_f > 0.65
    end
  end

  def range_of_count
    @contents.size * 65 / 100 + 1 .. @contents.size * 100 / 65
  end

  def exact_match
    retrieve_exact_content
    retrieve_functional_rule
  end

  def retrieve_exact_content
    content_ids = nil
    @contents.each_with_index do |content, index|
      content_patterns =
        ContentPattern.where(
          order: index + 1,
          count: @contents.size,
          word: content[:word],
          pos: content[:pos],
          conj_type: content[:conj_type]).all
      new_content_ids = content_patterns.map{|pattern| pattern.pattern_id}
      if content_ids.nil?
        content_ids = new_content_ids
      else
        content_ids &= new_content_ids
      end
      break if content_ids.size == 0
    end
    if content_ids.size > 0
      @exact_content_id = content_ids.first
    else
      if ContentPattern.count > 0
        @exact_content_id = ContentPattern.maximum(:pattern_id) + 1
      else
        @exact_content_id = 1
      end
      @contents.each_with_index do |content, index|
        ContentPattern.new(
          pattern_id: @exact_content_id,
          order: index + 1,
          count: @contents.size,
          word: content[:word],
          pos: content[:pos],
          conj_type: content[:conj_type]).save!
      end
    end
  end

  def retrieve_functional_rule
    functional_ids = nil
    @functionals.each_with_index do |functional, index|
      functional_patterns =
        FunctionalPattern.where(
          order: index + 1,
          count: @contents.size,
          word: functional[:word],
          prev_form: functional[:prev_form]).all
      new_functional_ids = functional_patterns.map{|pattern| pattern.pattern_id}
      if content_ids.nil?
        functional_ids = new_functional_ids
      else
        functional_ids &= new_functional_ids
      end
      break if functional_ids.size == 0
    end
    if content_ids.size > 0
      functional_id = functional_ids.first
    else
      if FunctionalPattern.count > 0
        functional_id = FunctionalPattern.maximum(:pattern_id) + 1
      else
        functional_id = 1
      end
      @functionals.each_with_index do |functional, index|
        FunctionalPattern.new(
          pattern_id: functional_id,
          order: index + 1,
          count: @functionals.size,
          word: functional[:word],
          prev_form: functional[:prev_form]).save!
      end
    end
    if functional_rule =
      FunctionalRule.where(
        content_id: @exact_content_id,
        functional_id: functional_id).first
      functional_rule.frequency += 1
      functional_rule.save!
    else
      FunctionalRule.new(
        content_id: @exact_content_id,
        functional_id: functional_id,
        frequency: 1).save!
    end
  end

  def initialize_state!
    @surface = ''
    @infinite = ''
    @current_pos = nil
    @new_pos = nil
    @prev_form = nil
    @conj_type = nil
    @conj_form = nil
    @contents = []
    @functionals = []
  end

  def parse_to_node(string)
    @node = @tagger.parseToNode(string)
  end

  def next_node?
    @node = @node.next
  end

  def end_of_sentence?
    @node.feature[/^BOS\/EOS/]
  end

  def surface
    @node.surface.force_encoding('utf-8')
  end

  def feature
    @node.feature.force_encoding('utf-8')
  end

  def conj_type
    case feature.split(',')[4]
    when '*'
      nil
    else
      feature.split(',')[4]
    end
  end

  def conj_form
    case feature.split(',')[5]
    when '*'
      nil
    else
      feature.split(',')[5]
    end
  end

  def infinite
    case feature.split(',')[6]
    when '*'
      surface
    else
      feature.split(',')[6]
    end
  end

  def functional_state?
    @functionals.size == @contents.size
  end

  def concat
    @current_pos =
      case @new_pos
      when :suffix_noun
        :noun
      when :suffix_verb
        :verb
      when :suffix_adjv
        :adjv
      when :prefix
        :noun
      else
        @new_pos
      end
    @infinite = @surface + infinite
    @surface << surface
    @conj_type = conj_type
    @conj_form = conj_form
  end

  def update
    if functional_state?
      @functionals << {
        word: @surface,
        prev_form: @prev_form
      }
    else
      @contents << {
        word: @infinite,
        pos: @current_pos,
        conj_type: @conj_type
      }
      @functionals << {
        word: '',
        prev_form: nil
      } unless @new_pos == :functional
    end
    @surface = surface
    @infinite = infinite
    @current_pos = @new_pos
    @conj_type = conj_type
    @prev_form = @conj_form
    @conj_form = conj_form
  end

  def finalize!
    if functional_state?
      @functionals << {
        word: @surface,
        prev_form: @prev_form
      }
    else
      @contents << {
        word: @infinite,
        pos: @current_pos,
        conj_type: @conj_type
      }
      @functionals << {
        word: '',
        prev_form: nil
      }
    end
  end

  def chunkable?
    if @new_pos == :functional
      if functional_state?
        false
      else
        true
      end
    else
      if functional_state?
        case @new_pos
        when :suffix_noun, :suffix_verb, :suffix_adjv
          false
        else
          true
        end
      elsif @current_pos == :noun && @new_pos == :noun
        false
      elsif @current_pos == :prefix
        false
      else
        case @new_pos
        when :suffix_noun, :suffix_verb, :suffix_adjv
          false
        else
          true
        end
      end
    end
  end

  def set_new_pos
    @new_pos =
      case feature[/^([^,]+)/]
      when '名詞'
        if feature[/非自立|特殊,助動詞語幹|接続詞的/]
          :functional
        else
          if feature[/接尾/]
            :suffix_noun
          else
            :noun
          end
        end
      when '接頭詞'
        :prefix
      when '動詞'
        if feature[/非自立/]
          :functional
        else
          if feature[/接尾/]
            :suffix_verb
          else
            :verb
          end
        end
      when '形容詞'
        if feature[/非自立/]
          :functional
        else
          if feature[/接尾/]
            :suffix_adjv
          else
            :adjv
          end
        end
      when '連体詞'
        :adnominal
      when '感動詞'
        :interjection
      when '副詞', '接続詞', '助詞', '助動詞', '記号', 'フィラー', 'その他'
        :functional
      else
        raise 'こんな品詞もありましたよ！：' + feature
      end
  end

  def eliza_respond(string)
    @eliza.respond(string)
  end
end
