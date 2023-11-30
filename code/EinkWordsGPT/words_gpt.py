#!/usr/bin/python
# -*- coding:utf-8 -*-

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



# import os
# os.environ['GPIOZERO_PIN_FACTORY'] = os.environ.get('GPIOZERO_PIN_FACTORY', 'mock')
# import gpiozero
# from gpiozero.pins.mock import MockFactory
# gpiozero.Device.pin_factory = MockFactory()

import sys
import os
pic_root = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'pic')
lib_root = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'lib')
font_root = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'font')
if os.path.exists(lib_root):
    sys.path.append(lib_root)

import logging
from waveshare_epd import epd7in3f
import time
from PIL import Image, ImageDraw, ImageFont
from PIL.Image import Resampling
import traceback
import itertools
import random
logging.basicConfig(level=logging.DEBUG)

# from grossary import words_phonetics
import json
from openai import OpenAI
from words_data import WordsDatabase, AdvancedWordFetcher, OpenAiChooser

import sqlite3
import os

from datetime import datetime
import pytz
import re


# Usage example
client = OpenAI()
# Database path
db_path = 'words_phonetics.db'
# Initialize database class
words_db = WordsDatabase(db_path)
# Initialize word fetcher
words_db = WordsDatabase(db_path)
word_fetcher = AdvancedWordFetcher(client)



# Function to count syllables based on dots
def count_syllables(word):
    # Count dots and stress symbols, subtract one if the first character is a stress symbol
    count = word.count('·') + word.count('ˈ') + word.count('ˌ')
    if word.startswith('ˈ') or word.startswith('ˌ'):
        count -= 1
    return count + 1

# Function to split words into syllables and get color for each syllable



class EPaperHardware:
    def __init__(self, epd_module):
        self.epd = epd_module.EPD()
        self.init_display()

    def init_display(self):
        self.epd.init()

    def clear_and_sleep(self):
        self.epd.Clear()
        self.epd.sleep()

    def get_display_size(self):
        return self.epd.width, self.epd.height

    def display_image(self, image):
        self.epd.display(self.epd.getbuffer(image))

    def clear_display(self):
        self.epd.Clear()

class EPaperDisplay:
    def __init__(self, hardware, font_root, scale_factor=2):
        self.hardware = hardware
        self.scale_factor = scale_factor
        self.width, self.height = [dim // scale_factor for dim in hardware.get_display_size()]
        self.font_root = font_root
        # Colors: Black, Red, Green, Blue, Red, Yellow, Orange
        self.pallete = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 165, 0), (255, 0, 165), (0, 255, 165)]
        self.setup_fonts()

    def setup_fonts(self):
        self.jp_font_path = os.path.join(self.font_root, 'HolidayMDJP.otf')
        self.jp_font_path_fallback = os.path.join(self.font_root, 'KouzanMouhituFontOTF.otf')
        self.ipa_font_path = os.path.join(self.font_root, 'arial.ttf')
        self.default_font_path = os.path.join(self.font_root, 'Font.ttc')

    def create_content_layout(self, item):
        image = Image.new('RGB', (self.width, self.height), (255,255,255))
        draw = ImageDraw.Draw(image)

        # Divide the display into 4 rows
        row_height = self.height // 4
        self.draw_phonetic(draw, item['phonetic'], 0, row_height)
        self.draw_word(draw, item['syllable_word'], row_height, row_height)
        self.draw_japanese(draw, item['japanese_synonym'], 2 * row_height, 2 * row_height)

        # Scale the image up to fit the display
        return image.resize((self.width * self.scale_factor, self.height * self.scale_factor), Resampling.LANCZOS)

    def draw_phonetic(self, draw, phonetic_text, start_y, row_height):
        phonetic_text_cleaned = phonetic_text.replace('·', '')
        font = ImageFont.truetype(self.ipa_font_path, self.find_font_size(phonetic_text_cleaned, self.ipa_font_path, self.width, row_height))
        syllables = self.split_word(phonetic_text, self.pallete)
        
        # Calculate the total width of the line
        total_width = sum(self.get_text_size(syllable.replace('·', ''), font)[0] for syllable, _ in syllables)
        
        # Calculate Y position for the entire line
        line_height = self.get_text_size(phonetic_text_cleaned, font)[1]
        line_y = start_y + (row_height - line_height) / 2
        
        x = (self.width - total_width) / 2
        for syllable, color in syllables:
            draw.text((x, line_y), syllable.replace('·', ''), font=font, fill=color)
            x += self.get_text_size(syllable.replace('·', ''), font)[0]

    def draw_word(self, draw, word_text, start_y, row_height):
        word_text_cleaned = word_text.replace('·', '')
        font = ImageFont.truetype(self.default_font_path, self.find_font_size(word_text_cleaned, self.default_font_path, self.width, row_height))
        syllables = self.split_word(word_text, self.pallete)
        
        # Calculate the total width of the line
        total_width = sum(self.get_text_size(syllable.replace('·', ''), font)[0] for syllable, _ in syllables)
        
        # Calculate Y position for the entire line
        line_height = self.get_text_size(word_text_cleaned, font)[1]
        line_y = start_y + (row_height - line_height) / 2
        
        x = (self.width - total_width) / 2
        for syllable, color in syllables:
            draw.text((x, line_y), syllable.replace('·', ''), font=font, fill=color)
            x += self.get_text_size(syllable.replace('·', ''), font)[0]



    def draw_japanese(self, draw, japanese_text, start_y, row_height):
        self.draw_japanese_with_hiragana(draw, japanese_text, self.jp_font_path, self.width, start_y, row_height)


    # def split_word(self, word):
    #     color_cycle = itertools.cycle(self.pallete)
    #     return [(part, next(color_cycle)) for part in re.split(r'([·ˈˌ])', word) if part]

    def split_word(self, word, colors):
        # Replace stress symbols with a preceding dot, except at the beginning
        if word.startswith('ˈ') or word.startswith('ˌ'):
            word = word[0] + word[1:].replace('ˈ', '·ˈ').replace('ˌ', '·ˌ')
        else:
            word = word.replace('ˈ', '·ˈ').replace('ˌ', '·ˌ')

        syllables = word.split('·')
        color_syllables = [(syllable, colors[i % len(colors)]) for i, syllable in enumerate(syllables)]
        return color_syllables

    def find_font_size(self, text, font_path, max_width, max_height, start_size=60, step=2):
        font_size = start_size
        font = ImageFont.truetype(font_path, font_size)
        while True:
            text_width, text_height = self.get_text_size(text, font)
            if text_width <= max_width and text_height <= max_height:
                break
            font_size -= step
            if font_size <= 0:
                break
            font = ImageFont.truetype(font_path, font_size)
        return font_size

    def get_text_size(self, text, font):
        dummy_image = Image.new('RGB', (100, 100))
        draw = ImageDraw.Draw(dummy_image)
        return draw.textbbox((0, 0), text, font=font)[2:]


    def is_char_supported(self, character, font_path, background_color=(255, 255, 255)):
        font = ImageFont.truetype(font_path, 20)
        image = Image.new('RGB', (40, 40), background_color)
        draw = ImageDraw.Draw(image)
        draw.text((5, 5), character, font=font, fill=(0, 0, 0))

        for x in range(image.width):
            for y in range(image.height):
                if image.getpixel((x, y)) != background_color:
                    return True
        return False

    def draw_kanji(self, draw,  text, x, y,font_paths, font_size):
        for char in text:
            for font_path in font_paths:
                if self.is_char_supported(char, font_path):
                    font = ImageFont.truetype(font_path, font_size)
                    break
                else:
                    # If no font supports the character, use the last font in the list
                    font = ImageFont.truetype(font_paths[-1], font_size)

            draw.text((x, y), char, font=font, fill=(0, 0, 0))
            x += font.getsize(char)[0]  # Update x position for next character


    def draw_japanese_with_hiragana(self, draw, text, jp_font_path, max_width, y, max_height):
        find_font_size = self.find_font_size
        get_text_size = self.get_text_size

        text = text.replace(" ", "").replace("(", "（").replace(")", "）")
        regex = re.compile(r'([一-龠々ァ-ンー-]+)（([ぁ-んァ-ンー-]+)）')

        plain_text = re.sub(r'（[ぁ-んァ-ンー-]+）', '', text)
        font_size = find_font_size(plain_text, jp_font_path, max_width, max_height)
        font = ImageFont.truetype(jp_font_path, font_size)

        pos_x = (max_width - get_text_size(plain_text, font)[0]) / 2
        y += (max_height - get_text_size(plain_text, font)[1]) / 2  # Center vertically in the row

        last_match_end = 0
        for match in regex.finditer(text):
            kanji_or_katakana, hiragana = match.groups()
            start, end = match.span()

            preceding_text = text[last_match_end:start]
            draw.text((pos_x, y), preceding_text, font=font, fill=(0, 0, 0))
            pos_x += get_text_size(preceding_text, font)[0]

            # draw.text((pos_x, y), re.sub(r'（[ぁ-んァ-ンー-]+）', '', kanji_or_katakana), font=font, fill=(0, 0, 0))
            font_paths = [self.jp_font_path, self.jp_font_path_fallback]
            self.draw_kanji(draw, re.sub(r'（[ぁ-んァ-ンー-]+）', '', kanji_or_katakana), pos_x, y, font_paths, font_size)

            kanji_or_katakana_width = get_text_size(kanji_or_katakana, font)[0]
            kanji_or_katakana_height = get_text_size(kanji_or_katakana, font)[1]

            hiragana_font_size = find_font_size(hiragana, jp_font_path, kanji_or_katakana_width, (max_height - kanji_or_katakana_height) / 2)
            hiragana_font = ImageFont.truetype(jp_font_path, hiragana_font_size)
            hiragana_x = pos_x + (kanji_or_katakana_width - get_text_size(hiragana, hiragana_font)[0]) / 2
            hiragana_y = y - get_text_size(hiragana, hiragana_font)[1] - 2
            draw.text((hiragana_x, hiragana_y), hiragana, font=hiragana_font, fill=(0, 0, 0))

            pos_x += kanji_or_katakana_width
            last_match_end = end

        remaining_text = text[last_match_end:]
        draw.text((pos_x, y), re.sub(r'（[ぁ-んァ-ンー-]+）', '', remaining_text), font=font, fill=(0, 0, 0))





if __name__=="__main__":
    # import logging
    # from waveshare_epd import epd7in3f
    # import time

    logging.basicConfig(level=logging.DEBUG)

    epd_module = epd7in3f
    epd_hardware = EPaperHardware(epd_module)
    epd_display = EPaperDisplay(epd_hardware, font_root)



    words_list = [
        # "impeccable"
    ]

    chooser = OpenAiChooser(words_db, word_fetcher, words_list=words_list)


    try:
        while True:
            item = chooser.choose()
            # item = chooser.choose()
            print("word: ", item)
            content_image = epd_display.create_content_layout(item)
            epd_hardware.display_image(content_image)
            time.sleep(300)  # Display each word for 5 minutes

    except Exception as e:
        print("Exception: ", str(e))
        logging.info(e)
    finally:
        epd_hardware.clear_and_sleep()

