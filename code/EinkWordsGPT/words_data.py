"""
Eink Words GPT Project
----------------------

Project Name: Eink Words GPT
Author: Lachlan CHEN
Website: https://lazying.art
GitHub: https://github.com/lachlanchen/

Description:
The Eink Words GPT project integrates the cutting-edge e-ink technology with the power of OpenAI's GPT models. 
Designed and developed by Lachlan CHEN, this project represents a unique and innovative approach to word learning. 
It features a dynamic word display system using a Raspberry Pi 5 and a Waveshare 7-color 7.3-inch e-ink display, 
selecting interesting and relevant words dynamically from OpenAI. This system is a part of the 'Art of Lazying' theme, 
reflecting a philosophy of efficient and enjoyable learning. The Eink Words GPT project is open-source, inviting 
contributions from the community to further enrich this learning experience.

"""


import json
import random
from openai import OpenAI

import sqlite3
import os

from datetime import datetime
import pytz
import csv
from pykakasi import kakasi
import re

class JSONParsingError(Exception):
    """Exception raised for errors in the JSON parsing."""
    def __init__(self, message, json_string, error_pos=None):
        self.message = message
        self.json_string = json_string
        self.error_pos = error_pos
        self.error_details = f"{self.message}\nError Position: {self.error_pos}" if self.error_pos else f"{self.message}"
        full_message = f"{self.error_details}\nJSON String: {self.json_string}"
        super().__init__(full_message)

def remove_second_parentheses(text):
    regex = re.compile(r'(（[^）]*）)(（[^）]*）)')
    return re.sub(regex, lambda match: match.group(1), text)



def transcribe_japanese(text):
    kks = kakasi()
    kks.setMode("J", "H")  # Japanese to Hiragana
    kks.setMode("K", "H")  # Katakana to Hiragana
    conv = kks.getConverter()

    result = ""
    current_chunk = ""
    is_kanji_or_katakana = False

    for char in text:
        hiragana = conv.do(char)

        if '\u4E00' <= char <= '\u9FFF':  # Kanji
            if not is_kanji_or_katakana:
                is_kanji_or_katakana = True
                current_chunk = ""
            current_chunk += hiragana
            result += char
        elif '\u30A0' <= char <= '\u30FF':  # Katakana
            if not is_kanji_or_katakana:
                is_kanji_or_katakana = True
                current_chunk = ""
            current_chunk += hiragana
            result += char
        else:  # Hiragana or others
            if is_kanji_or_katakana:
                result += f"({current_chunk}){char}"
                is_kanji_or_katakana = False
            else:
                result += char

    if is_kanji_or_katakana:  # Remaining kanji or katakana chunk at the end
        result += f"({current_chunk})"

    return result

# Function to remove text inside parentheses
def remove_text_inside_parentheses(text):
    while '（' in text and '）' in text:
        start = text.find('（')
        end = text.find('）') + 1
        text = text[:start] + text[end:]
    return text

def clean_english(text):
    return text.replace(" ", "").replace(".", "·")

def clean_japanese(text):
    return text.replace(".", "").replace("·", "").replace(" ", "").replace("(", "（").replace(")", "）")


def clean_and_transcribe(word_details):
    
    for word in word_details:
        # Update phonetic field
        word["phonetic"] = word["phonetic"].replace(".", "·").replace(" ", "")

        # Update word_details field
        word["japanese_synonym"] = word["japanese_synonym"].replace(".", "").replace("·", "").replace(" ", "").replace("(", "（").replace(")", "）")

        # Clean and transcribe japanese_synonym
        if "japanese_synonym" in word:
            # clean_synonym = remove_text_inside_parentheses(word["japanese_synonym"])
            clean_synonym = re.sub(r'（[ぁ-んァ-ンー-]+）', '', word["japanese_synonym"])  # Remove hiragana in parentheses
            word["japanese_synonym"] = remove_second_parentheses(transcribe_japanese(clean_synonym))  # Replace with your transcription function

    return word_details

class WordsDatabase:
    def __init__(self, db_path):
        self.db_path = db_path
        self.conn = None
        if os.path.exists(db_path):
            self.conn = sqlite3.connect(db_path)
            self.cursor = self.conn.cursor()

    def log_history_update(self, old_new_word_details_pairs, history_csv_path='data/words_update_history.csv'):
        with open(history_csv_path, 'a', newline='', encoding='utf-8') as history_file:
            history_writer = csv.writer(history_file)
            for old_details, new_details in old_new_word_details_pairs:
                for key in old_details.keys():
                    old_value = old_details[key]
                    new_value = new_details[key]
                    if old_value != new_value:
                        history_writer.writerow([key, old_value, "→", new_value])

    def word_exists(self, word):
        if self.conn:
            self.cursor.execute("SELECT COUNT(*) FROM words_phonetics WHERE word = ?", (word,))
            return self.cursor.fetchone()[0] > 0
        return False

    
    def insert_word_details(self, word_details, force=False):
        if self.conn:
            print("insert words: ", word_details)
            word = word_details['word'] # .lower()
            syllable_word = clean_english(word_details['syllable_word']) # .lower())
            phonetic = clean_english(word_details['phonetic'])
            japanese_synonym = remove_second_parentheses(clean_japanese(word_details['japanese_synonym']))

            try:
                if force:
                    # UPSERT operation: Update if exists, insert if not
                    self.cursor.execute("""
                        INSERT INTO words_phonetics (word, syllable_word, phonetic, japanese_synonym)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(word) DO UPDATE SET
                            syllable_word = excluded.syllable_word,
                            phonetic = excluded.phonetic,
                            japanese_synonym = excluded.japanese_synonym;
                    """, (word, syllable_word, phonetic, japanese_synonym))
                else:
                    # Insert new record, ignore on duplicate
                    self.cursor.execute("""
                        INSERT INTO words_phonetics (word, syllable_word, phonetic, japanese_synonym)
                        VALUES (?, ?, ?, ?);
                    """, (word, syllable_word, phonetic, japanese_synonym))

                self.conn.commit()
            except sqlite3.Error as e:
                print(f"SQLite Error: {e}")

 

    def update_word_details(self, word_details, force=False):
        if self.conn:
            word = word_details.get('word', '').lower()

            # Prepare data and query for dynamic update
            data_to_update = []
            update_parts = []

            for key in ['syllable_word', 'phonetic', 'japanese_synonym']:
                if key in word_details:
                    cleaned_value = clean_english(word_details[key]) if key != 'japanese_synonym' else clean_japanese(word_details[key])
                    data_to_update.append(cleaned_value)
                    update_parts.append(f"{key} = ?")

            if not update_parts:
                print("No data to update.")
                return

            query = f"UPDATE words_phonetics SET {', '.join(update_parts)} WHERE word = ?"
            data_to_update.append(word)

            try:
                # Execute the query with the values
                self.cursor.execute(query, data_to_update)
                self.conn.commit()
            except sqlite3.Error as e:
                print(f"SQLite Error: {e}")




    def get_total_word_count(self):
        if self.conn:
            self.cursor.execute("SELECT COUNT(*) FROM words_phonetics")
            return self.cursor.fetchone()[0]
        return 0

    def fetch_and_clean_word_details(self, words):
        updated_words = []
        for word in words:
            word_details = self.find_word_details(word)

            if word_details:
                original_word_details = word_details.copy()

                # Clean English and Japanese text
                word_details['syllable_word'] = clean_english(word_details.get('syllable_word', ''))
                word_details['phonetic'] = clean_english(word_details.get('phonetic', ''))
                word_details['japanese_synonym'] = clean_japanese(word_details.get('japanese_synonym', ''))

                # Check if cleaning resulted in changes
                if word_details != original_word_details:
                    self.update_word_details(word_details, force=True)
                    updated_words.append(word_details)

        return updated_words

    def update_all_words(self, batch_size=10):
        total_words = self.get_total_word_count()
        processed = 0

        while processed < total_words:
            # Fetch a batch of words from the database
            words_batch = self.fetch_words_batch(processed, batch_size)
            words_to_update = []

            for word_detail in words_batch:
                cleaned_word_detail = self.fetch_and_clean_word_details([word_detail["word"]])
                if cleaned_word_detail != word_detail:
                    words_to_update.extend(cleaned_word_detail)

            # Update the database with cleaned and updated word details
            for updated_word in words_to_update:
                print("updateing words: ", updated_word)
                self.update_word_details(updated_word, force=True)

            processed += len(words_batch)

    def find_word_details(self, word):
        if self.conn:
            self.cursor.execute("SELECT word, syllable_word, phonetic, japanese_synonym FROM words_phonetics WHERE word = ?", (word.lower(),))
            result = self.cursor.fetchone()
            if result:
                return {"word": result[0], "syllable_word": result[1], "phonetic": result[2], "japanese_synonym": result[3]}
        return None

    def fetch_random_words(self, num_words):
        if self.conn:
            query = "SELECT word, syllable_word, phonetic, japanese_synonym FROM words_phonetics ORDER BY RANDOM() LIMIT ?"
            self.cursor.execute(query, (num_words,))
            rows = self.cursor.fetchall()
            # Convert each row to a dictionary
            return [{"word": row[0], "syllable_word": row[1], "phonetic": row[2], "japanese_synonym": row[3]} for row in rows]
        else:
            return []

    def fetch_last_10_words(self):
        if self.conn:
            query = "SELECT word, syllable_word, phonetic, japanese_synonym FROM words_phonetics ORDER BY rowid DESC LIMIT 10"
            self.cursor.execute(query)
            rows = self.cursor.fetchall()
            return [{"word": row[0], "syllable_word": row[1], "phonetic": row[2], "japanese_synonym": row[3]} for row in rows]
        else:
            return []

    

    def fetch_words_batch(self, offset, limit):
        if self.conn:
            query = "SELECT word, syllable_word, phonetic, japanese_synonym FROM words_phonetics LIMIT ? OFFSET ?"
            self.cursor.execute(query, (limit, offset))
            rows = self.cursor.fetchall()
            return [{"word": row[0], "syllable_word": row[1], "phonetic": row[2], "japanese_synonym": row[3]} for row in rows]
        else:
            return []

    def update_from_word_details_correction_csv(self, word_details_correction_csv_path):
        history_csv_path = 'data/words_update_history.csv'

        with open(word_details_correction_csv_path, 'r+', newline='', encoding='utf-8') as file:
            reader = csv.DictReader(file)
            lines = list(reader)
            remaining_lines = []

            for line in lines:
                # Fetch old details from the database
                old_detail = self.find_word_details(line['word'])

                # Update word details in the database
                self.insert_word_details(line, force=True)

                # Fetch updated details for logging
                updated_detail = self.find_word_details(line['word'])

                if old_detail and updated_detail:
                    # Log changes to history if there were any updates
                    old_new_pairs = [(old_detail, updated_detail)]
                    self.log_history_update(old_new_pairs, history_csv_path)
                else:
                    remaining_lines.append(line)

            # Remove updated items from the error CSV
            file.seek(0)
            file.truncate()
            writer = csv.DictWriter(file, fieldnames=reader.fieldnames)
            writer.writeheader()
            writer.writerows(remaining_lines)

    def update_from_word_list_csv(self, words_update_csv_path, fetcher):
        words = []

        # Extract words from data/words_update.csv
        with open(words_update_csv_path, 'r', newline='', encoding='utf-8') as file:
            reader = csv.reader(file)
            for row in reader:
                words.append(row[0])

        word_details = []
        for word in words:
            word_detail = self.find_word_details(word)
            if word_detail is None:
                # Fetch word details if not found in the database
                word_detail = fetcher.fetch_word_details([word], self)[0]
            word_details.append(word_detail)

        # Recheck and fetch details for the words
        rechecked_details = fetcher.recheck_word_details(word_details, self)

        

        # Update the database with these details
        self.update_from_list(word_details_list, words_update_csv_path)

    def update_from_list(self, word_details_list, words_update_csv_path):
        history_csv_path = 'data/words_update_history.csv'

        for new_details in word_details_list:
            # Fetch old details from the database
            old_detail = self.find_word_details(new_details['word'])

            # Update the word details in the database
            self.insert_word_details(new_details, force=True)

            # Fetch updated details for logging
            updated_detail = self.find_word_details(new_details['word'])

            if old_detail and updated_detail:
                # Log changes to history if there were any updates
                old_new_pairs = [(old_detail, updated_detail)]
                self.log_history_update(old_new_pairs, history_csv_path)

        # Remove updated words from data/words_update.csv
        self.remove_words_from_csv(words_update_csv_path, word_details_list)


    def remove_words_from_csv(self, csv_path, word_details_list):
        updated_words = {details['word'] for details in word_details_list}

        with open(csv_path, 'r+', newline='', encoding='utf-8') as file:
            reader = csv.reader(file)
            remaining_words = [row[0] for row in reader if row[0] not in updated_words]

            file.seek(0)
            file.truncate()

            writer = csv.writer(file)
            for word in remaining_words:
                writer.writerow([word])



    def close(self):
        if self.conn:
            self.conn.close()


class AdvancedWordFetcher:
    def __init__(self, client, max_retries=3):
        self.client = client
        self.max_retries = max_retries
        self.examples = self.load_examples()
        self.model_name = ["gpt-3.5-turbo", "gpt-4-1106-preview"]

    def load_examples(self):
        examples_file_path = 'data/word_examples.csv'
        if os.path.exists(examples_file_path):
            with open(examples_file_path, mode='r', newline='', encoding='utf-8') as file:
                reader = csv.DictReader(file)
                example_list = list(reader)

                print("example_list: ", example_list)

                if len(example_list) > 1:
                   return example_list

        return [
            {"word": "abstraction", "syllable_word": "ab·strac·tion", "phonetic": "ˈæb·stræk·ʃən", "japanese_synonym": "抽象（ちゅうしょう）"},
            {"word": "paradox", "syllable_word": "par·a·dox", "phonetic": "ˈpær·ə·dɒks", "japanese_synonym": "逆説（ぎゃくせつ）"}
        ]

    def save_examples(self):
        examples_file_path = 'data/word_examples.csv'
        with open(examples_file_path, mode='w', newline='', encoding='utf-8') as file:
            writer = csv.DictWriter(file, fieldnames=self.examples[0].keys())
            writer.writeheader()
            writer.writerows(self.examples)


    def extract_and_parse_json(self, text):
        bracket_pattern = r'\[.*?\]'
        matches = re.findall(bracket_pattern, text, re.DOTALL)

        if not matches:
            raise JSONParsingError("No JSON string found in text", text)

        json_string = matches[0]

        try:
            parsed_json = json.loads(json_string)
            if len(parsed_json) == 0:
                raise JSONParsingError("Parsed JSON string is empty", json_string)
            return parsed_json
        except json.JSONDecodeError as e:
            raise JSONParsingError(f"JSON Decode Error: {e}", json_string)


    def load_propensities(self):
        propensities_file_path = 'data/words_propensity.txt'
        propensities = []
        if os.path.exists(propensities_file_path):
            with open(propensities_file_path, 'r') as file:
                # Only include lines that are not empty and do not start with '#'
                propensities = [line.strip() for line in file if line.strip() and not line.startswith('#')]
        return propensities



    def fetch_words(self, num_words, word_database):
        propensities = self.load_propensities()
        unique_words = []
        messages = []

        # Choose the appropriate prompt based on whether propensities are available
        if propensities:
            criteria_list = "\n".join([f"{i+1}) {propensity}" for i, propensity in enumerate(propensities)])
            user_message = (
                f"Generate a python list of {num_words*5} unique advanced lowercase words that meet one or more of the following criteria:\n"
                f"{criteria_list}\n"
                "Format the list for compatibility with json.loads, starting with [ and ending with ]. "
                # "and include the word's tendency or special characteristic next to each word."
                "The output should be like ['word 1', 'word 2', ..., 'word N']."
            )
        else:
            user_message = (
                f"Think wildly and provide me with a python list of {num_words*5} unique advanced lowercase words that are often used in formal readings. "
                "Give me only the plain python list compatible with json.loads and start with [ and end with ]."
                "The output should be like ['word 1', 'word 2', ..., 'word N']. "
            )

        messages = [
            {"role": "system", "content": "You are an assistant with a vast vocabulary and creativity. You are excellent in providing python list of words without any extra information. "},
            {"role": "user", "content": user_message}
        ]

        for _ in range(self.max_retries):
            try:
                

                response = self.client.chat.completions.create(
                    model=self.model_name[1],
                    messages=messages
                )

                words_list = self.extract_and_parse_json(response.choices[0].message.content)
                unique_words = [word for word in words_list if not word_database.word_exists(word)]
                if unique_words:
                    break

            except JSONParsingError as jpe:
                print(f"JSON parsing failed: {jpe.error_details}")
                # messages.append({"role": "system", "content": response.choices[0].message.content})
                messages.append({"role": "system", "content": jpe.json_string})
                messages.append({"role": "user", "content": f"JSON parsing failed: {jpe.error_details}"})
                continue
            except Exception as e:
                print(f"An unexpected error occurred: {e}")
                raise e

        if not unique_words:
            raise RuntimeError("Failed to fetch unique words after maximum retries.")

        return unique_words

    def fetch_word_details(self, words, word_database, num_words_phonetic=10):
        random_words = random.sample(words, min(num_words_phonetic, len(words)))
        

        detailed_list_message = (
            "For each word, we need to correctly format the syllable_word (with · separating syllables), phonetic transcription (phonemes also separated by ·), and the Japanese synonym. "
            "Ensure the word syllables and phonetic separation are syncronized. "
            "In the case of Japanese synonyms, the hiragana (furigana) should follow directly after the kanji and katakana. For example, 'その後' should be followed by its furigana '（ご)', instead of repeating the kanji as in 'その後（そのご)'. "
            "Consider '容易にする' – the correct form is '容易（ようい）にする', placing 'する' outside the parentheses to align with standard formatting. "
            "In 'もの悲しい', the proper format is 'もの悲（かな）しい', where the hiragana directly follows its respective kanji. "
            "Remember, no dots in the Japanese synonym and hiragana should be placed inside parentheses right after the kanji/katakana. "
            "The output format should RESEMBLE: {}. "
            "The words to process are: {}."
        ).format(json.dumps(self.examples, ensure_ascii=False, separators=(',', ':')), ', '.join(random_words))


                
        messages = [
            {"role": "system", "content": "You are an assistant skilled in linguistics, capable of providing detailed phonetic and linguistic attributes for given words."},
            {"role": "user", "content": detailed_list_message}
        ]

        

        for _ in range(self.max_retries):
            try:

                print(f"Querying {random_words} from OpenAI...")

                response = self.client.chat.completions.create(
                    model=self.model_name[1],
                    messages=messages
                )
                
                word_phonetics = self.extract_and_parse_json(response.choices[0].message.content)



                # Save word details to database
                for detail in word_phonetics:
                    word_database.insert_word_details(detail)
                    # self.recheck_syllable_and_phonetic(word_phonetics, word_database)
                    # self.recheck_japanese_synonym(word_phonetics, word_database)

                self.examples= word_phonetics[0:2]
                self.save_examples()
                return word_phonetics
            except JSONParsingError as jpe:
                print(f"JSON parsing failed: {jpe.error_details}")
                # messages.append({"role": "system", "content": response.choices[0].message.content})
                messages.append({"role": "system", "content": jpe.json_string})
                messages.append({"role": "user", "content": f"JSON parsing failed: {jpe.error_details}"})
                continue
            except Exception as e:
                print(f"An unexpected error occurred: {e}")
                raise e
            else:
                print("Fetched word details successfully.")
                return word_phonetics

        raise RuntimeError("Failed to parse response after maximum retries.")

    def recheck_word_details(self, word_details, word_database=None, num_words_phonetic=10, recheck=False):
        word_details = clean_and_transcribe(word_details)

        words = [{k: v for k, v in word.items() if k in ['word']} for word in word_details]

        print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
        print("Rechking whole details: ", word_details)

        detailed_list_message = (
            "Let's recheck each word's details and ensure they are correctly formatted. "
            "The syllable_word should have central dots · separating syllables, and the phonetic transcription should have phonemes also separated by ·. "
            "Ensure the word syllables and phonetic separation are syncronized and have equal number of separations. "
            "For Japanese synonyms, let's place the hiragana (furigana) accurately. Take 'もの悲しい' as an example – it should be formatted as 'もの悲（かな）しい', with the hiragana following the kanji. "
            "'容易にする' is best formatted as '容易（ようい）にする', moving 'する' after the parentheses for clarity. "
            "For 'その後', it should simply be 'その後（ご)', without repeating the hiragana in parentheses. "
            "No dots should be in the Japanese synonym, and hiragana should always be placed in parentheses right after the kanji/katakana. "
            "Please output as SAME FORMAT and correct these words in the list as needed: {}."
        ).format(json.dumps(word_details, ensure_ascii=False, separators=(',', ':')))


        messages = [
            {"role": "system", "content": "You are an assistant skilled in linguistics, capable of providing detailed phonetic and linguistic attributes for given words."},
            {"role": "user", "content": detailed_list_message}
        ]

        for _ in range(self.max_retries):
            try:
                print(f"Rechecking {words} from OpenAI...")
                
                

                response = self.client.chat.completions.create(
                    # model="gpt-3.5-turbo",
                    # model="gpt-4",
                    model=self.model_name[1],
                    messages=messages
                )
                word_phonetics = self.extract_and_parse_json(response.choices[0].message.content)
                print("Parsed rechecked result: ", word_phonetics)
                print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")
                # Save word details to database
                for detail in word_phonetics:
                    if word_database:
                        word_database.insert_word_details(detail)

                # self.recheck_syllable_and_phonetic(word_phonetics, word_database)
                # self.recheck_japanese_synonym(word_phonetics, word_database)
                return word_phonetics

            except JSONParsingError as jpe:
                print(f"JSON parsing failed: {jpe.error_details}")
                # messages.append({"role": "system", "content": response.choices[0].message.content})
                messages.append({"role": "system", "content": jpe.json_string})
                messages.append({"role": "user", "content": f"JSON parsing failed: {jpe.error_details}"})
                continue
            except Exception as e:
                print(f"An unexpected error occurred: {e}")
                raise e
            else:
                print("Fetched and rechecked word details successfully.")
                return word_phonetics
        raise RuntimeError("Failed to parse response after maximum retries.")


    def recheck_syllable_and_phonetic(self, word_details, word_database=None):

        word_details = clean_and_transcribe(word_details)

        print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
        print("Rechecking syllable and phonetics: ", word_details)

        # Prepare examples excluding the Japanese synonyms
        example_list = [{k: v for k, v in example.items() if k != 'japanese_synonym'} for example in self.examples]

        # Extract the relevant parts from word_details
        word_details_formatted = [{k: v for k, v in word.items() if k in ['word', 'syllable_word', 'phonetic']} for word in word_details]


        words = [{k: v for k, v in word.items() if k in ['word']} for word in word_details]

        detailed_list_message = (
            "Let's recheck each word's details and ensure they are correctly formatted. "
            "The syllable_word should have central dots · separating syllables, and the phonetic transcription should have phonemes also separated by ·. "
            "Ensure the word syllables and phonetic separation are syncronized and have equal number of separations. "
            "Please output as SAME FORMAT and correct these words in the list as needed: {}."
        ).format(json.dumps(word_details_formatted, ensure_ascii=False, separators=(',', ':')))

        messages = [
            {"role": "system", "content": "You are an assistant skilled in linguistics, capable of providing accurate and detailed phonetic and linguistic attributes for given words. You are excellent in separate words and their phonetics into consistent and accurate separations with '·'."},
            {"role": "user", "content": detailed_list_message}
        ]

        for _ in range(self.max_retries):
            try:
                print(f"Rechecking syllable and phonetic for {words} from OpenAI...")
                
                

                response = self.client.chat.completions.create(
                    model=self.model_name[1],
                    messages=messages
                )

                print("Rechecked result: ", response.choices[0].message.content)
                word_phonetics = self.extract_and_parse_json(response.choices[0].message.content)
                print("Parsed result: ", word_phonetics)
                print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")

                # Save word details to database
                for detail in word_phonetics:
                    if word_database:
                        word_database.update_word_details(detail)
                return word_phonetics
            except JSONParsingError as jpe:
                print(f"JSON parsing failed: {jpe.error_details}")
                # messages.append({"role": "system", "content": response.choices[0].message.content})
                messages.append({"role": "system", "content": jpe.json_string})
                messages.append({"role": "user", "content": f"JSON parsing failed: {jpe.error_details}"})
                continue
            except Exception as e:
                print(f"An unexpected error occurred: {e}")
                raise e
            else:
                print("Fetched and rechecked word details successfully.")
                return word_phonetics


        raise RuntimeError("Failed to parse response after maximum retries.")

    def recheck_japanese_synonym(self, word_details, word_database=None):
        print("Rechecking Japanese synonym: ", word_details)
        word_details = clean_and_transcribe(word_details)

        print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")

        print("Clean and transribed: ", word_details)

        # Prepare examples including only the word and Japanese synonym
        example_list = [{k: v for k, v in example.items() if k in ['word', 'japanese_synonym']} for example in self.examples]

        # Extract the relevant parts from word_details
        word_details_formatted = [{k: v for k, v in word.items() if k in ['word', 'japanese_synonym']} for word in word_details]

        words = [{k: v for k, v in word.items() if k in ['word']} for word in word_details]


        detailed_list_message = (
            "Please provide the correct Japanese synonym for each word, ensuring that hiragana (furigana) is accurately placed after consecutive kanji and katakana. "
            "The hiragana should be in parentheses following the kanji/katakana. "
            "For Japanese synonyms, let's place the hiragana (furigana) accurately. Take 'もの悲しい' as an example – it should be formatted as 'もの悲（かな）しい', with the hiragana following the kanji. "
            "'容易にする' is best formatted as '容易（ようい）にする', moving 'する' after the parentheses for clarity. "
            "For 'その後', it should simply be 'その後（ご)', without repeating the kanji in hiragana. "
            "No dots should be in the Japanese synonym, and hiragana should always be placed in parentheses right after the kanji/katakana. "
            "Avoid any unnecessary repetition of hiragana and ensure no hiragana is placed between the kanji/katakana and the parentheses. "
            "Please output as SAME FORMAT python list of dict and correct these words in the list as needed : {}."
        ).format(json.dumps(word_details_formatted, ensure_ascii=False, separators=(',', ':')))

        messages = [
            {"role": "system", "content": "You are an assistant skilled in linguistics, capable of providing detailed phonetic and linguistic attributes for given words. You are excellent in providing hiragana (furigana) for consecutive kanji/katakana. "},
            {"role": "user", "content": detailed_list_message}
        ]

        for _ in range(self.max_retries):
            try:
                print(f"Fetching Japanese synonyms for {word_details_formatted} from OpenAI...")
                
                

                response = self.client.chat.completions.create(
                    model=self.model_name[1],
                    messages=messages
                )

                print("Rechecked Japanese synonym: ", response.choices[0].message.content)
                word_phonetics = self.extract_and_parse_json(response.choices[0].message.content)
                print("Parsed rechecked result: ", word_phonetics)
                print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")

                # Save word details to database
                for detail in word_phonetics:
                    if word_database:
                        word_database.update_word_details(detail)

                return word_phonetics
            except JSONParsingError as jpe:
                print(f"JSON parsing failed: {jpe.error_details}")
                # messages.append({"role": "system", "content": response.choices[0].message.content})
                messages.append({"role": "system", "content": jpe.json_string})
                messages.append({"role": "user", "content": f"JSON parsing failed: {jpe.error_details}"})
                continue
            except Exception as e:
                print(f"An unexpected error occurred: {e}")
                raise e
            else:
                print("Fetched and rechecked word details successfully.")
                return word_phonetics                

        raise RuntimeError("Failed to parse response after maximum retries.")





# Example usage
# words_db = WordsDatabase(db_path)
# word_fetcher = AdvancedWordFetcher(client)
# chooser = OpenAiChooser(words_db, word_fetcher)

# chosen_word = chooser.choose()
# print(chosen_word)

class OpenAiChooser:
    def __init__(self, db, word_fetcher, words_list=None):
        self.db = db
        self.word_fetcher = word_fetcher
        self.original_words_list = words_list
        self.current_words = []
        self.words_iterator = iter([])

        # Process the provided words_list only if it's not None
        if self.original_words_list:
            self.process_words_list()

    def process_words_list(self):
        self.current_words = []
        for word in self.original_words_list:
            word_details = self.db.find_word_details(word)
            if not word_details:
                word_details = self.word_fetcher.fetch_word_details([word], self.db)[0]
            self.current_words.append(word_details)
        self.words_iterator = iter(self.current_words)

    def _is_daytime_in_hk(self):
        hk_timezone = pytz.timezone('Asia/Hong_Kong')
        hk_time = datetime.now(hk_timezone)
        # return 8 <= hk_time.hour < 24  # Daytime hours in Hong Kong
        return True

    def fetch_new_words(self):
        # If original_words_list is None, fetch new words dynamically
        if not self.original_words_list:
            if self._is_daytime_in_hk():
                words = self.word_fetcher.fetch_words(10, self.db)
                openai_words = self.word_fetcher.fetch_word_details(words, self.db, num_words_phonetic=10)
                db_words = self.db.fetch_random_words(10)
            else:
                db_words = self.db.fetch_random_words(20)
                openai_words = []

            self.current_words = openai_words + db_words
            random.shuffle(self.current_words)
        else:
            # Repopulate current_words using original_words_list
            self.process_words_list()

        self.words_iterator = iter(self.current_words)

    def choose(self):
        try:
            return next(self.words_iterator)
        except StopIteration:
            print("StopIteration encountered in choose method.")
            if self.original_words_list:
                print("Restarting iterator from the beginning.")
                self.words_iterator = iter(self.current_words)
                return next(self.words_iterator)
            else:
                print("Fetching new words as original_words_list is None.")
                self.fetch_new_words()
                return next(self.words_iterator)

    def get_current_words(self):
        return self.current_words

if __name__ == "__main__":


    # Usage example
    client = OpenAI()


    # Database path
    db_path = 'words_phonetics.db'

    # Initialize database class
    words_db = WordsDatabase(db_path)

    # Initialize word fetcher
    word_fetcher = AdvancedWordFetcher(client)

    # words = word_fetcher.fetch_words(50, words_db)
    # print("words: ", words)


    # # Fetch word details
    # word_details = word_fetcher.fetch_word_details(words, words_db)
    # print("words: ", word_details)


    

    # Example usage
    words_db = WordsDatabase(db_path)
    word_fetcher = AdvancedWordFetcher(client)
    chooser = OpenAiChooser(words_db, word_fetcher)

    # chosen_word = chooser.choose()
    # print(chosen_word)

    chooser.get_current_words()

    # Close the database connection
    words_db.close()


