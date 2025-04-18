from openai import OpenAI
from words_data import WordsDatabase, AdvancedWordFetcher
import csv
from pykakasi import kakasi

import re

from words_data import remove_second_parentheses

def update_last_10_words(database, fetcher):
    # Fetch the last 10 words from the database
    last_10_words = database.fetch_last_10_words()

    print(last_10_words)

    # Extract just the words for rechecking
    words_to_recheck = [word_detail['word'] for word_detail in last_10_words]

    # Recheck word details using AdvancedWordFetcher
    rechecked_details = fetcher.recheck_word_details(words_to_recheck, database)

    print(rechecked_details)
    
    # Update the database with rechecked details
    for details in rechecked_details:
        database.insert_word_details(details, force=True)

def log_updated_words(updated_words, log_file='data/words_updated.csv'):
    with open(log_file, 'a', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        for word in updated_words:
            writer.writerow([word])

def get_logged_words(log_file='data/words_updated.csv'):
    logged_words = set()
    try:
        with open(log_file, 'r', newline='', encoding='utf-8') as file:
            reader = csv.reader(file)
            for row in reader:
                logged_words.add(row[0])
    except FileNotFoundError:
        pass  # File not found, return empty set
    return logged_words

def remove_consecutive_parenthesis_in_batches(database, fetcher, batch_size=10):
    logged_words = get_logged_words()
    total_words = database.get_total_word_count()
    processed = 0

    while processed < total_words:
        words_batch = database.fetch_words_batch(processed, batch_size)
        # print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
        # print("before update: ", words_batch)
        words_to_recheck = [word_detail['word'] for word_detail in words_batch if word_detail['word'] not in logged_words]

        if len(words_to_recheck) > 0:
            # print("The words are all processed. ")
            # continue

            # rechecked_details = fetcher.recheck_word_details(words_to_recheck, database, word_details=words_batch)
            # print("after update: ", rechecked_details)
            rechecked_details = words_batch
            # print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")

            updated_words = []
            for details in rechecked_details:
                details["japanese_synonym"] = remove_second_parentheses(details["japanese_synonym"])
                database.insert_word_details(details, force=True)
                updated_words.append(details['word'])

            log_updated_words(updated_words)
        processed += len(words_batch)

def update_database_in_batches(database, fetcher, batch_size=10):
    logged_words = get_logged_words()
    total_words = database.get_total_word_count()
    processed = 0

    while processed < total_words:
        words_batch = database.fetch_words_batch(processed, batch_size)
        # print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
        # print("before update: ", words_batch)
        words_to_recheck = [word_detail['word'] for word_detail in words_batch if word_detail['word'] not in logged_words]

        if len(words_to_recheck) > 0:
            # print("The words are all processed. ")
            # continue

            rechecked_details = fetcher.recheck_word_details(words_batch, database)
            # print("after update: ", rechecked_details)
            # print(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")

            updated_words = []
            for details in rechecked_details:
                # database.insert_word_details(details, force=True)
                updated_words.append(details['word'])

            log_updated_words(updated_words)
        processed += len(words_batch)


def batch_update_syllable_and_phonetic(database, fetcher, batch_size=10):
    total_words = database.get_total_word_count()
    processed = 0

    while processed < total_words:
        words_batch = database.fetch_words_batch(processed, batch_size)

        # Extract just the word, syllable, and phonetic details
        words_detail = [{'word': word['word'], 'syllable_word': word['syllable_word'], 'phonetic': word['phonetic']} for word in words_batch]

        # Recheck details
        rechecked_details = fetcher.recheck_syllable_and_phonetic(words_detail, database)

        # Update the database with rechecked details
        # for details in rechecked_details:
        #     database.update_word_details(details, force=True)

            # pass

        # break

        processed += len(words_batch)


def batch_update_japanese_synonyms(database, fetcher, batch_size=10):
    total_words = database.get_total_word_count()
    processed = 0

    while processed < total_words:
        words_batch = database.fetch_words_batch(processed, batch_size)

        # Extract just the word and Japanese synonym details
        # words_detail = [{'word': word['word'], 'japanese_synonym': word['japanese_synonym']} for word in words_batch]

        # Fetch new Japanese synonyms
        updated_synonyms = fetcher.recheck_japanese_synonym(words_batch, database)

        # Update the database with the new synonyms
        # for details in updated_synonyms:
        #     database.update_word_details(details, force=True)
            # pass

        # break

        processed += len(words_batch)


def fetch_and_recheck_words(database, fetcher, words_list):
    for word in words_list:
        word = word.lower()  # Standardize the word to lowercase

        # Fetch word details from database or OpenAI
        word_detail = database.find_word_details(word)
        if not word_detail:
            # # Fetch details if not found in database
            # fetched_details = fetcher.fetch_word_details([word], database)
            # if fetched_details:
            #     word_detail = fetched_details[0]
            # else:
            #     print(f"Failed to fetch details for word: {word}")
            #     continue

            continue

        # Apply recheck functions
        # rechecked_details_all = fetcher.recheck_word_details([word_detail], database)[0]
        # rechecked_syllable_phonetic = fetcher.recheck_syllable_and_phonetic([word_detail], database)[0]
        rechecked_japanese_synonym = fetcher.recheck_japanese_synonym([word_detail], database)[0]

        # Update the database with the final rechecked details
        database.update_word_details(rechecked_japanese_synonym, force=True)



# Usage example
client = OpenAI()  # Assuming you have initialized OpenAI client

# Database path
db_path = 'words_phonetics.db'

# Initialize database and word fetcher
words_db = WordsDatabase(db_path)
word_fetcher = AdvancedWordFetcher(client)

# # Update the last 10 words
# update_last_10_words(words_db, word_fetcher)

# remove_consecutive_parenthesis_in_batches(words_db, word_fetcher)

# Update the database in batches
# update_database_in_batches(words_db, word_fetcher, 5)
# words_db.update_all_words(batch_size=10)

# batch_update_syllable_and_phonetic(words_db, word_fetcher, 5)
# batch_update_japanese_synonyms(words_db, word_fetcher, 5)


# words_list = ["baguette"]
words_list = ["circumlocution"]
fetch_and_recheck_words(words_db, word_fetcher, words_list)


# Close the database connection
words_db.close()
